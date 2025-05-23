module physpkg
  !-----------------------------------------------------------------------
  ! Purpose:
  !
  ! Provides the interface to a simple CAM physics package
  !
  !-----------------------------------------------------------------------

  use shr_kind_mod,    only: r8 => shr_kind_r8
  use spmd_utils,      only: masterproc, mpicom
  use physics_types,   only: physics_state, physics_tend, physics_state_set_grid, &
                             physics_ptend, physics_update,                       &
                             physics_type_alloc, physics_ptend_dealloc,           &
                             physics_state_alloc, physics_state_dealloc,          &
                             physics_tend_alloc, physics_tend_dealloc
  use phys_grid,       only: get_ncols_p
  use phys_gmean,      only: gmean_mass
  use ppgrid,          only: begchunk, endchunk, pcols, pver, pverp
  use camsrfexch,      only: cam_out_t, cam_in_t, cam_export

  ! Note: ideal_phys is true for Held-Suarez (1994) physics
  use cam_control_mod, only: moist_physics, adiabatic, ideal_phys, kessler_phys, tj2016_phys
  use phys_control,    only: phys_getopts
  use perf_mod,        only: t_barrierf, t_startf, t_stopf, t_adj_detailf
  use cam_logfile,     only: iulog
  use cam_abortutils,  only: endrun
  use shr_sys_mod,     only: shr_sys_flush

  implicit none
  private
  save

  ! Public methods
  public phys_register ! register physics methods
  public phys_init     ! Public initialization method
  public phys_run1     ! First phase of the public run method
  public phys_run2     ! Second phase of the public run method
  public phys_final    ! Public finalization method

  ! Private module data

  ! Physics buffer indices
  integer :: teout_idx     = 0
  integer :: dtcore_idx    = 0

  integer :: qini_idx      = 0
  integer :: cldliqini_idx = 0
  integer :: cldiceini_idx = 0

  logical :: state_debug_checks  ! Debug physics_state.

  character(len=32) :: cam_take_snapshot_before ! Physics routine to take a snapshot "before"
  character(len=32) :: cam_take_snapshot_after  ! Physics routine to take a snapshot "after"
  integer           :: cam_snapshot_before_num ! tape number for before snapshots
  integer           :: cam_snapshot_after_num  ! tape number for after snapshots


!=======================================================================
contains
!=======================================================================

  subroutine phys_register
    !-----------------------------------------------------------------------
    !
    ! Purpose: Register constituents and physics buffer fields.
    !
    !-----------------------------------------------------------------------
    use shr_kind_mod,       only: r8 => shr_kind_r8

    use physconst,          only: mwh2o, cpwv
    use constituents,       only: cnst_add, cnst_chk_dim
    use physics_buffer,     only: pbuf_init_time, dtype_r8, pbuf_add_field, pbuf_cam_snapshot_register

    use cam_diagnostics,    only: diag_register
    use chemistry,          only: chem_register
    use tracers,            only: tracers_register
    use check_energy,       only: check_energy_register
    use kessler_cam,        only: kessler_register
    use tj2016_cam,         only: thatcher_jablonowski_register

    !---------------------------Local variables-----------------------------
    !
    integer  :: mm       ! constituent index
    !-----------------------------------------------------------------------

    ! Get physics options
    call phys_getopts(state_debug_checks_out = state_debug_checks, &
                      cam_take_snapshot_before_out= cam_take_snapshot_before, &
                      cam_take_snapshot_after_out = cam_take_snapshot_after, &
                      cam_snapshot_before_num_out = cam_snapshot_before_num, &
                      cam_snapshot_after_num_out  = cam_snapshot_after_num)

    ! Initialize dyn_time_lvls
    call pbuf_init_time()

    ! Register water vapor.
    ! ***** N.B. ***** This must be the first call to cnst_add so that
    !                  water vapor is constituent 1.
    if (moist_physics) then
      call cnst_add('Q', mwh2o, cpwv, 1.E-12_r8, mm, &
           longname='Specific humidity', readiv=.true., is_convtran1=.true.)
    else
      call cnst_add('Q', mwh2o, cpwv, 0.0_r8, mm, &
           longname='Specific humidity', readiv=.false., is_convtran1=.true.)
    end if

    if (kessler_phys) then
      call kessler_register()
    else if (tj2016_phys) then
      call thatcher_jablonowski_register()
    end if

    ! Fields for physics package diagnostics
    call pbuf_add_field('QINI',      'physpkg', dtype_r8, (/pcols,pver/), qini_idx)

    if (moist_physics) then
      call pbuf_add_field('CLDLIQINI', 'physpkg', dtype_r8, (/pcols,pver/), cldliqini_idx)
      call pbuf_add_field('CLDICEINI', 'physpkg', dtype_r8, (/pcols,pver/), cldiceini_idx)
    end if

    ! check energy package
    call check_energy_register

    ! Register diagnostics PBUF
    call diag_register()

    ! register chemical constituents including aerosols ...
    call chem_register()

    ! Register test tracers
    call tracers_register()

    ! All tracers registered, check that the dimensions are correct
    call cnst_chk_dim()

    ! ***NOTE*** No registering constituents after the call to cnst_chk_dim.

    ! This needs to be last as it requires all pbuf fields to be added
    if (cam_snapshot_before_num > 0 .or. cam_snapshot_after_num > 0) then
        call pbuf_cam_snapshot_register()
    end if

  end subroutine phys_register

  !======================================================================================

  subroutine phys_inidat( cam_out, pbuf2d )
    use cam_abortutils,      only: endrun

    use physics_buffer,      only: physics_buffer_desc

    use cam_grid_support,    only: cam_grid_check, cam_grid_id
    use cam_grid_support,    only: cam_grid_get_dim_names

    ! Dummy arguments
    type(cam_out_t), intent(inout)     :: cam_out(begchunk:endchunk)
    type(physics_buffer_desc), pointer :: pbuf2d(:,:)

    ! Local variables
    character(len=8)                   :: dim1name, dim2name
    integer                            :: grid_id ! grid ID for data mapping
    character(len=*), parameter        :: subname='phys_inidat'

    !   dynamics variables are handled in dyn_init - here we read variables
    !      needed for physics but not dynamics

    grid_id = cam_grid_id('physgrid')
    if (.not. cam_grid_check(grid_id)) then
      call endrun(subname//': Internal error, no "physgrid" grid')
    end if
    call cam_grid_get_dim_names(grid_id, dim1name, dim2name)

  end subroutine phys_inidat

  !======================================================================================

  subroutine phys_init( phys_state, phys_tend, pbuf2d, cam_in, cam_out )

    !-----------------------------------------------------------------------
    !
    ! Initialization of physics package.
    !
    !-----------------------------------------------------------------------

    use physics_buffer,     only: physics_buffer_desc, pbuf_initialize, pbuf_get_index
    use physconst,          only: physconst_init

    use cam_control_mod,    only: initial_run
    use check_energy,       only: check_energy_init
    use chemistry,          only: chem_init, chem_is_active
    use cam_diagnostics,    only: diag_init
    use held_suarez_cam,    only: held_suarez_init
    use kessler_cam,        only: kessler_cam_init
    use tj2016_cam,         only: thatcher_jablonowski_init
    use tracers,            only: tracers_init
    use wv_saturation,      only: wv_sat_init
    use phys_debug_util,    only: phys_debug_init
    use qneg_module,        only: qneg_init
    use cam_snapshot,       only: cam_snapshot_init

    ! Input/output arguments
    type(physics_state), pointer       :: phys_state(:)
    type(physics_tend ), pointer       :: phys_tend(:)
    type(physics_buffer_desc), pointer :: pbuf2d(:,:)

    type(cam_in_t), intent(in)         :: cam_in(begchunk:endchunk)
    type(cam_out_t),intent(inout)      :: cam_out(begchunk:endchunk)

    ! local variables
    integer :: lchnk
    !-----------------------------------------------------------------------

    call physics_type_alloc(phys_state, phys_tend, begchunk, endchunk, pcols)

    do lchnk = begchunk, endchunk
      call physics_state_set_grid(lchnk, phys_state(lchnk))
    end do

    !---------------------------------------------------------------------------
    ! Initialize any variables in physconst which are not temporally and/or
    !   spatially constant
    !---------------------------------------------------------------------------
    call physconst_init()

    ! Initialize debugging a physics column
    call phys_debug_init()

    call pbuf_initialize(pbuf2d)

    ! diag_init makes addfld calls for dynamics fields that are output from
    ! the physics decomposition
    call diag_init(pbuf2d)

    call check_energy_init()
    teout_idx  = pbuf_get_index('TEOUT')
    dtcore_idx = pbuf_get_index('DTCORE')

    ! wv_saturation is relatively independent of everything else and
    ! low level, so init it early. Must at least do this before radiation.
    if (kessler_phys .or. tj2016_phys) then
      call wv_sat_init()
    end if

    call tracers_init()

    if (initial_run) then
      call phys_inidat(cam_out, pbuf2d)
    end if

    if (ideal_phys) then
      call held_suarez_init(pbuf2d)
    else if (kessler_phys) then
      call kessler_cam_init(pbuf2d)
    else if (tj2016_phys) then
      call thatcher_jablonowski_init(pbuf2d)
    end if

    if (chem_is_active()) then
      ! Prognostic chemistry.
      call chem_init(phys_state,pbuf2d)
    end if

    ! Initialize qneg3 and qneg4
    call qneg_init()

    ! Initialize the snapshot capability
    call cam_snapshot_init(cam_in, cam_out, pbuf2d, begchunk)

  end subroutine phys_init

  !======================================================================================

  subroutine phys_run1(phys_state, ztodt, phys_tend, pbuf2d,  cam_in, cam_out)
    !-----------------------------------------------------------------------
    !
    ! Purpose:
    ! First part of atmospheric physics package before updating of surface models
    !
    !-----------------------------------------------------------------------
    use time_manager,    only: get_nstep
    use cam_diagnostics, only: diag_allocate, diag_physvar_ic
    use check_energy,    only: check_energy_gmean

    use physics_buffer,  only: physics_buffer_desc, pbuf_get_chunk, pbuf_allocate
    !
    ! Input arguments
    !
    real(r8), intent(in) :: ztodt            ! physics time step unless nstep=0
    !
    ! Input/Output arguments
    !
    type(physics_state), intent(inout), dimension(begchunk:endchunk) :: phys_state
    type(physics_tend ), intent(inout), dimension(begchunk:endchunk) :: phys_tend

    type(physics_buffer_desc), pointer, dimension(:,:) :: pbuf2d
    type(cam_in_t),                     dimension(begchunk:endchunk) :: cam_in
    type(cam_out_t),                    dimension(begchunk:endchunk) :: cam_out
    !-----------------------------------------------------------------------
    !
    !---------------------------Local workspace-----------------------------
    !
    integer                            :: c                    ! indices
    integer                            :: nstep                ! current timestep number
    type(physics_buffer_desc), pointer :: phys_buffer_chunk(:)
    type(physics_ptend)                :: ptend(begchunk:endchunk) ! indivdual parameterization tendencies

    call t_startf ('physpkg_st1')
    nstep = get_nstep()

    ! Compute total energy of input state and previous output state
    call t_startf ('chk_en_gmean')
    call check_energy_gmean(phys_state, pbuf2d, ztodt, nstep)
    call t_stopf ('chk_en_gmean')

    call pbuf_allocate(pbuf2d, 'physpkg')
    call diag_allocate()

    !-----------------------------------------------------------------------
    ! Advance time information
    !-----------------------------------------------------------------------

    call phys_timestep_init(phys_state, cam_in, cam_out, pbuf2d)

    call t_stopf ('physpkg_st1')

#ifdef TRACER_CHECK
    call gmean_mass ('before tphysbc DRY', phys_state)
#endif

    !-----------------------------------------------------------------------
    ! Tendency physics before flux coupler invocation
    !-----------------------------------------------------------------------
    !

    call t_barrierf('sync_bc_physics', mpicom)
    call t_startf ('bc_physics')
    call t_adj_detailf(+1)

    !$OMP PARALLEL DO PRIVATE (C, phys_buffer_chunk)
    do c = begchunk, endchunk

      phys_buffer_chunk => pbuf_get_chunk(pbuf2d, c)

      call t_startf ('diag_physvar_ic')
      call diag_physvar_ic ( c,  phys_buffer_chunk, cam_out(c), cam_in(c) )
      call t_stopf ('diag_physvar_ic')

      call tphysbc (ztodt, phys_state(c), phys_tend(c), phys_buffer_chunk,     &
           cam_out(c), cam_in(c) )
    end do

    call t_adj_detailf(-1)
    call t_stopf ('bc_physics')

#ifdef TRACER_CHECK
    call gmean_mass ('between DRY', phys_state)
#endif

  end subroutine phys_run1

  !======================================================================================

  subroutine phys_run2(phys_state, ztodt, phys_tend, pbuf2d,  cam_out, cam_in)
    !-----------------------------------------------------------------------
    !
    ! Purpose:
    ! Second part of atmospheric physics package after updating of surface models
    !
    !-----------------------------------------------------------------------
    use physics_buffer,         only: physics_buffer_desc, pbuf_get_chunk, pbuf_deallocate, pbuf_update_tim_idx


    use cam_diagnostics, only: diag_deallocate
    !
    ! Input arguments
    !
    real(r8), intent(in) :: ztodt                       ! physics time step unless nstep=0
    !
    ! Input/Output arguments
    !
    type(physics_state), intent(inout), dimension(begchunk:endchunk) :: phys_state
    type(physics_tend ), intent(inout), dimension(begchunk:endchunk) :: phys_tend
    type(physics_buffer_desc),pointer, dimension(:,:)     :: pbuf2d

    type(cam_out_t),     intent(inout), dimension(begchunk:endchunk) :: cam_out
    type(cam_in_t),      intent(inout), dimension(begchunk:endchunk) :: cam_in
    !
    !-----------------------------------------------------------------------
    !---------------------------Local workspace-----------------------------
    !
    integer :: c                                 ! chunk index
    integer :: ncol                              ! number of columns
    type(physics_buffer_desc),pointer, dimension(:)     :: phys_buffer_chunk

    !-----------------------------------------------------------------------
    ! Tendency physics after coupler
    ! Not necessary at terminal timestep.
    !-----------------------------------------------------------------------
    !

    call t_barrierf('sync_ac_physics', mpicom)
    call t_startf ('ac_physics')
    call t_adj_detailf(+1)

!$OMP PARALLEL DO PRIVATE (C, NCOL, phys_buffer_chunk)

    do c = begchunk, endchunk
      ncol = get_ncols_p(c)
      phys_buffer_chunk => pbuf_get_chunk(pbuf2d, c)

       call tphysac(ztodt, cam_in(c), cam_out(c), phys_state(c), phys_tend(c), &
            phys_buffer_chunk)
    end do                    ! Chunk loop

    call t_adj_detailf(-1)
    call t_stopf('ac_physics')

#ifdef TRACER_CHECK
    call gmean_mass ('after tphysac FV:WET)', phys_state)
#endif

    call t_startf ('physpkg_st2')
    call pbuf_deallocate(pbuf2d, 'physpkg')

    call pbuf_update_tim_idx()
    call diag_deallocate()
    call t_stopf ('physpkg_st2')

  end subroutine phys_run2

  !======================================================================================

  subroutine phys_final( phys_state, phys_tend, pbuf2d)
    use physics_buffer, only : physics_buffer_desc, pbuf_deallocate
    !-----------------------------------------------------------------------
    !
    ! Purpose:
    ! Finalization of physics package
    !
    !-----------------------------------------------------------------------
    ! Input/output arguments
    type(physics_state), pointer :: phys_state(:)
    type(physics_tend ), pointer :: phys_tend(:)
    type(physics_buffer_desc), pointer :: pbuf2d(:,:)

    if(associated(pbuf2d)) then
      call pbuf_deallocate(pbuf2d,'global')
      deallocate(pbuf2d)
    end if
    deallocate(phys_state)
    deallocate(phys_tend)

  end subroutine phys_final

  !======================================================================================

  subroutine tphysac (ztodt, cam_in, cam_out, state, tend, pbuf)
    !-----------------------------------------------------------------------
    !
    ! Tendency physics
    !
    !   o Moist Held-Suarez configuration: Compute surface fluxes and PBL mixing
    !-----------------------------------------------------------------------
    use physics_buffer,  only: physics_buffer_desc, pbuf_get_field, pbuf_old_tim_idx
    use physics_types,   only: physics_state, physics_tend, physics_state_check
    use physics_types,   only: physics_dme_adjust, set_dry_to_wet
    use constituents,    only: cnst_get_ind, pcnst
    use cam_diagnostics, only: diag_phys_tend_writeout, diag_surf
    use tj2016_cam,      only: thatcher_jablonowski_sfc_pbl_hs_tend
    use dycore,          only: dycore_is
    use check_energy,    only: calc_te_and_aam_budgets
    use cam_history,     only: hist_fld_active
    use cam_snapshot,    only: cam_snapshot_all_outfld
    use cam_snapshot,    only: cam_snapshot_ptend_outfld

    ! Arguments
    !
    real(r8),                  intent(in)    :: ztodt ! Two times model timestep (2 delta-t)

    type(cam_in_t),            intent(inout) :: cam_in
    type(cam_out_t),           intent(inout) :: cam_out
    type(physics_state),       intent(inout) :: state
    type(physics_tend ),       intent(inout) :: tend
    type(physics_buffer_desc), pointer       :: pbuf(:)

    !---------------------------Local workspace-----------------------------

    type(physics_ptend)                      :: ptend  ! indivdual parameterization tendencies
    real(r8)                                 :: tmp_q(pcols, pver)
    real(r8)                                 :: tmp_cldliq(pcols, pver)
    real(r8)                                 :: tmp_cldice(pcols, pver)
    real(r8), pointer                        :: dtcore(:,:)
    real(r8), pointer                        :: qini(:,:)
    real(r8), pointer                        :: cldliqini(:,:)
    real(r8), pointer                        :: cldiceini(:,:)
    integer                                  :: ixcldliq
    integer                                  :: ixcldice
    integer                                  :: k
    integer                                  :: ncol
    integer                                  :: itim_old

    real(r8) :: tmp_trac  (pcols,pver,pcnst) ! tmp space
    real(r8) :: tmp_pdel  (pcols,pver)       ! tmp space
    real(r8) :: tmp_ps    (pcols)            ! tmp space
    !--------------------------------------------------------------------------

    ! number of active atmospheric columns
    ncol  = state%ncol
    ! Associate pointers with physics buffer fields
    itim_old = pbuf_old_tim_idx()

    ! Validate the physics state.
    if (state_debug_checks) then
      call physics_state_check(state, name="before tphysac")
    end if

    call pbuf_get_field(pbuf, qini_idx, qini)
    if (moist_physics) then
      call pbuf_get_field(pbuf, cldliqini_idx, cldliqini)
      call pbuf_get_field(pbuf, cldiceini_idx, cldiceini)
    else
      allocate(cldliqini(pcols, pver))
      cldliqini = 0.0_r8
      allocate(cldiceini(pcols, pver))
      cldiceini = 0.0_r8
    end if

    call calc_te_and_aam_budgets(state, 'pAP')

    !=========================
    ! Compute physics tendency
    !=========================
    if (tj2016_phys) then
       ! Update surface, PBL and modified Held-Suarez forcings
       call thatcher_jablonowski_sfc_pbl_hs_tend(state, ptend, ztodt, cam_in)
       call physics_update(state, ptend, ztodt, tend)
    end if

    ! FV: convert dry-type mixing ratios to moist here because
    !     physics_dme_adjust assumes moist. This is done in p_d_coupling for
    !     other dynamics. Bundy, Feb 2004.
    !
    if (moist_physics .and. (dycore_is('LR') .or. dycore_is('FV3'))) then
      call set_dry_to_wet(state)    ! Physics had dry, dynamics wants moist
    end if

    if (moist_physics) then
      ! Scale dry mass and energy (does nothing if dycore is EUL or SLD)
      call cnst_get_ind('CLDLIQ', ixcldliq, abort=.false.)
      call cnst_get_ind('CLDICE', ixcldice, abort=.false.)
      tmp_q     (:ncol,:pver) = state%q(:ncol,:pver,1)
      if (ixcldliq > 0) then
        tmp_cldliq(:ncol,:pver) = state%q(:ncol,:pver,ixcldliq)
      else
        tmp_cldliq(:ncol,:pver) = 0.0_r8
      end if
      if (ixcldice > 0) then
        tmp_cldice(:ncol,:pver) = state%q(:ncol,:pver,ixcldice)
      else
        tmp_cldice(:ncol,:pver) = 0.0_r8
      end if

      ! For not 'FV'|'FV3', physics_dme_adjust is called for energy diagnostic purposes only.
      ! So, save off tracers
      if (.not.(dycore_is('FV').or.dycore_is('FV3')) .and. &
           (hist_fld_active('SE_pAM').or.hist_fld_active('KE_pAM').or.hist_fld_active('WV_pAM').or.&
           hist_fld_active('WL_pAM').or.hist_fld_active('WI_pAM'))) then
        tmp_trac(:ncol,:pver,:pcnst) = state%q(:ncol,:pver,:pcnst)
        tmp_pdel(:ncol,:pver)        = state%pdel(:ncol,:pver)
        tmp_ps(:ncol)                = state%ps(:ncol)
        !
        ! pint, lnpint,rpdel are altered by dme_adjust but not used for tendencies in dynamics of SE
        ! we do not reset them to pre-dme_adjust values
        !
        if (dycore_is('SE')) call set_dry_to_wet(state)

        if (trim(cam_take_snapshot_before) == "physics_dme_adjust") then
           call cam_snapshot_all_outfld(cam_snapshot_before_num, state, tend, cam_in, cam_out, pbuf)
        end if

        call physics_dme_adjust(state, tend, qini, ztodt)

        if (trim(cam_take_snapshot_after) == "physics_dme_adjust") then
           call cam_snapshot_all_outfld(cam_snapshot_after_num, state, tend, cam_in, cam_out, pbuf)
        end if

        call calc_te_and_aam_budgets(state, 'pAM')
        ! Restore pre-"physics_dme_adjust" tracers
        state%q(:ncol,:pver,:pcnst) = tmp_trac(:ncol,:pver,:pcnst)
        state%pdel(:ncol,:pver)     = tmp_pdel(:ncol,:pver)
        state%ps(:ncol)             = tmp_ps(:ncol)
      end if

      if (dycore_is('LR') .or. dycore_is('FV3')) then
        call physics_dme_adjust(state, tend, qini, ztodt)
        call calc_te_and_aam_budgets(state, 'pAM')
      end if

    else
      tmp_q     (:ncol,:pver) = 0.0_r8
      tmp_cldliq(:ncol,:pver) = 0.0_r8
      tmp_cldice(:ncol,:pver) = 0.0_r8
      call calc_te_and_aam_budgets(state, 'pAM')
    end if

    ! store T in buffer for use in computing dynamics T-tendency in next timestep
    call pbuf_get_field(pbuf, dtcore_idx, dtcore,                             &
         start=(/1,1,itim_old/), kount=(/pcols,pver,1/) )
    do k = 1,pver
      dtcore(:ncol,k) = state%t(:ncol,k)
    end do

    call diag_phys_tend_writeout (state, pbuf,  tend, ztodt,                  &
         tmp_q, tmp_cldliq, tmp_cldice, qini, cldliqini, cldiceini)

    call diag_surf(cam_in, cam_out, state, pbuf)

    if (.not. moist_physics) then
      deallocate(cldliqini)
      deallocate(cldiceini)
    end if

  end subroutine tphysac

  !======================================================================================

  subroutine tphysbc (ztodt, state, tend, pbuf, cam_out, cam_in )
    !-----------------------------------------------------------------------
    !
    ! Evaluate and apply physical processes
    !
    ! The current simplified physical parameterization packages are:
    ! 0) no physics forcing, adiabatic
    ! 1) dry Held-Suarez forcing, see Held and Suarez (BAMS, 1994)
    ! 2) Kessler warm-rain precipitation, see Klemp et al. (JAMES, 2015) and DCMIP-2016
    ! 3) "moist Held-Suarez" physics package by Thatcher and Jablonowski (GMD, 2016)
    !
    !-----------------------------------------------------------------------

    use physics_buffer,    only: physics_buffer_desc, pbuf_get_field
    use physics_buffer,    only: pbuf_get_index, pbuf_old_tim_idx
    use physics_buffer,    only: dyn_time_lvls
    use physics_types,     only: physics_state_check, physics_tend_init
    use constituents,      only: cnst_get_ind

    use cam_diagnostics,   only: diag_phys_writeout, diag_state_b4_phys_write
    use cam_diagnostics,   only: diag_conv_tend_ini, diag_conv, diag_export
    use cam_history,       only: outfld
    use time_manager,      only: get_nstep
    use check_energy,      only: check_energy_chng, check_energy_fix, check_energy_timestep_init
    use check_energy,      only: check_tracers_data, check_tracers_init, check_tracers_chng
    use check_energy,      only: calc_te_and_aam_budgets
    use chemistry,         only: chem_is_active, chem_timestep_tend
    use held_suarez_cam,   only: held_suarez_tend
    use kessler_cam,       only: kessler_tend
    use tj2016_cam,        only: thatcher_jablonowski_precip_tend
    use dycore,            only: dycore_is
    use cam_snapshot,      only: cam_snapshot_all_outfld
    use cam_snapshot,      only: cam_snapshot_ptend_outfld

    ! Arguments

    real(r8),                  intent(in)    :: ztodt ! model time increment

    type(physics_state),       intent(inout) :: state
    type(physics_tend ),       intent(inout) :: tend
    type(physics_buffer_desc), pointer       :: pbuf(:)

    type(cam_out_t),           intent(inout) :: cam_out
    type(cam_in_t),            intent(inout) :: cam_in

    !---------------------------Local workspace-----------------------------

    type(physics_ptend)      :: ptend       ! indivdual parameterization tendencies
    integer                  :: nstep       ! current timestep number
    integer                  :: lchnk       ! chunk identifier
    integer                  :: ncol        ! number of atmospheric columns
    integer                  :: itim_old
    integer                  :: ixcldliq
    integer                  :: ixcldice

    ! physics buffer fields for total energy and mass adjustment
    real(r8), pointer        :: teout(:)
    real(r8), pointer        :: qini(:,:)
    real(r8), pointer        :: cldliqini(:,:)
    real(r8), pointer        :: cldiceini(:,:)
    real(r8), pointer        :: dtcore(:,:)

    real(r8)                 :: zero(pcols) ! array of zeros
    real(r8)                 :: flx_heat(pcols)
    type(check_tracers_data) :: tracerint   ! energy integrals and cummulative boundary fluxes
    !-----------------------------------------------------------------------

    call t_startf('bc_init')

    zero = 0._r8

    lchnk = state%lchnk
    ncol  = state%ncol

    nstep = get_nstep()

    ! Associate pointers with physics buffer fields
    itim_old = pbuf_old_tim_idx()

    ! Associate pointers with physics buffer fields
    call pbuf_get_field(pbuf, teout_idx, teout, (/1,itim_old/), (/pcols,1/))
    call pbuf_get_field(pbuf, dtcore_idx, dtcore, start=(/1,1,itim_old/), kount=(/pcols,pver,1/) )

    call pbuf_get_field(pbuf, qini_idx, qini)
    if (moist_physics) then
      call pbuf_get_field(pbuf, cldliqini_idx, cldliqini)
      call pbuf_get_field(pbuf, cldiceini_idx, cldiceini)
    end if

    ! Set accumulated physics tendencies to 0
    tend%dtdt(:ncol,:pver) = 0._r8
    tend%dudt(:ncol,:pver) = 0._r8
    tend%dvdt(:ncol,:pver) = 0._r8
    tend%flx_net(:ncol)    = 0._r8

    ! Verify state coming from the dynamics
    if (state_debug_checks) then
      call physics_state_check(state, name="before tphysbc (dycore?)")
    end if

    ! Dump out "before tphysbc" state
    call diag_state_b4_phys_write(state)

    ! compute mass integrals of input tracers state
    call check_tracers_init(state, tracerint)

    call t_stopf('bc_init')

    !===================================================
    ! Global mean total energy fixer and AAM diagnostics
    !===================================================
    call calc_te_and_aam_budgets(state, 'pBF')

    call t_startf('energy_fixer')

    if (adiabatic .and. (.not. dycore_is('EUL'))) then
      call check_energy_fix(state, ptend, nstep, flx_heat)
      call physics_update(state, ptend, ztodt, tend)
      call check_energy_chng(state, tend, "chkengyfix", nstep, ztodt, zero, zero, zero, flx_heat)
      call outfld( 'EFIX', flx_heat    , pcols, lchnk   )
    end if

    call t_stopf('energy_fixer')

    call calc_te_and_aam_budgets(state, 'pBP')

    ! Save state for convective tendency calculations.
    call diag_conv_tend_ini(state, pbuf)

    qini(:ncol,:pver) = state%q(:ncol,:pver,1)

    call cnst_get_ind('CLDLIQ', ixcldliq, abort=.false.)
    call cnst_get_ind('CLDICE', ixcldice, abort=.false.)
    if (moist_physics) then
      if (ixcldliq > 0) then
        cldliqini(:ncol,:pver) = state%q(:ncol,:pver,ixcldliq)
      end if
      if (ixcldice > 0) then
        cldiceini(:ncol,:pver) = state%q(:ncol,:pver,ixcldice)
      end if
    end if

    call outfld('TEOUT', teout       , pcols, lchnk   )
    call outfld('TEINP', state%te_ini, pcols, lchnk   )
    call outfld('TEFIX', state%te_cur, pcols, lchnk   )

    ! T tendency due to dynamics
    if( nstep > dyn_time_lvls-1 ) then
      dtcore(:ncol,:pver) = (state%t(:ncol,:pver) - dtcore(:ncol,:pver))/ztodt
      call outfld( 'DTCORE', dtcore, pcols, lchnk )
    end if

    !===================================================
    ! Compute physics tendency
    !===================================================
    if (ideal_phys) then

      if (trim(cam_take_snapshot_before) == "held_suarez_tend") then
         call cam_snapshot_all_outfld(cam_snapshot_before_num, state, tend, cam_in, cam_out, pbuf)
      end if

      call held_suarez_tend(state, ptend, ztodt)
      if ( (trim(cam_take_snapshot_after) == "held_suarez_tend") .and.       &
           (trim(cam_take_snapshot_before) == trim(cam_take_snapshot_after))) then
         call cam_snapshot_ptend_outfld(ptend, lchnk)
      end if
      call physics_update(state, ptend, ztodt, tend)

      if (trim(cam_take_snapshot_after) == "held_suarez_tend") then
         call cam_snapshot_all_outfld(cam_snapshot_after_num, state, tend, cam_in, cam_out, pbuf)
      end if

    else if (kessler_phys) then

      if (trim(cam_take_snapshot_before) == "kessler_tend") then
         call cam_snapshot_all_outfld(cam_snapshot_before_num, state, tend, cam_in, cam_out, pbuf)
      end if

      call kessler_tend(state, ptend, ztodt, pbuf)
      if ( (trim(cam_take_snapshot_after) == "kessler_tend") .and.            &
           (trim(cam_take_snapshot_before) == trim(cam_take_snapshot_after))) then
         call cam_snapshot_ptend_outfld(ptend, lchnk)
      end if
      call physics_update(state, ptend, ztodt, tend)

      if (trim(cam_take_snapshot_after) == "kessler_tend") then
         call cam_snapshot_all_outfld(cam_snapshot_after_num, state, tend, cam_in, cam_out, pbuf)
      end if

    else if (tj2016_phys) then
       ! Compute the large-scale precipitation

       if (trim(cam_take_snapshot_before) == "thatcher_jablonowski_precip_tend") then
          call cam_snapshot_all_outfld(cam_snapshot_before_num, state, tend, cam_in, cam_out, pbuf)
       end if

       call thatcher_jablonowski_precip_tend(state, ptend, ztodt, pbuf)
       if ( (trim(cam_take_snapshot_after) == "thatcher_jablonowski_precip_tend") .and. &
            (trim(cam_take_snapshot_before) == trim(cam_take_snapshot_after))) then
          call cam_snapshot_ptend_outfld(ptend, lchnk)
       end if
       call physics_update(state, ptend, ztodt, tend)

       if (trim(cam_take_snapshot_after) == "thatcher_jablonowski_precip_tend") then
          call cam_snapshot_all_outfld(cam_snapshot_after_num, state, tend, cam_in, cam_out, pbuf)
       end if
    end if

    ! Can't turn on conservation error messages unless the appropriate heat
    ! surface flux is computed and supplied as an argument to
    ! check_energy_chng to account for how the simplified physics forcings are
    ! changing the total exnergy.
    call check_energy_chng(state, tend, "tphysidl", nstep, ztodt, zero, zero, zero, zero)

    if (chem_is_active()) then
      call t_startf('simple_chem')

      call check_tracers_init(state, tracerint)

      if (trim(cam_take_snapshot_before) == "chem_timestep_tend") then
         call cam_snapshot_all_outfld(cam_snapshot_before_num, state, tend, cam_in, cam_out, pbuf)
      end if

      call chem_timestep_tend(state, ptend, cam_in, cam_out, ztodt, pbuf)
      if ( (trim(cam_take_snapshot_after) == "chem_timestep_tend") .and.      &
           (trim(cam_take_snapshot_before) == trim(cam_take_snapshot_after))) then
         call cam_snapshot_ptend_outfld(ptend, lchnk)
      end if
      call physics_update(state, ptend, ztodt, tend)

      if (trim(cam_take_snapshot_after) == "chem_timestep_tend") then
         call cam_snapshot_all_outfld(cam_snapshot_after_num, state, tend, cam_in, cam_out, pbuf)
      end if

      call check_tracers_chng(state, tracerint, "chem_timestep_tend", nstep, ztodt, cam_in%cflx)

      call t_stopf('simple_chem')
    end if

    call t_startf('bc_history_write')

    call diag_phys_writeout(state, pbuf)
    call diag_conv(state, ztodt, pbuf)

    call t_stopf('bc_history_write')

    ! Save total enery after physics for energy conservation checks
    teout = state%te_cur

    call cam_export(state, cam_out, pbuf)

  end subroutine tphysbc

  !======================================================================================

  subroutine phys_timestep_init(phys_state, cam_in, cam_out, pbuf2d)
    !--------------------------------------------------------------------------
    !
    ! Purpose: The place for parameterizations to call per timestep initializations.
    !          Generally this is used to update time interpolated fields from
    !          boundary datasets.
    !
    !--------------------------------------------------------------------------
    use physics_types,       only: physics_state
    use physics_buffer,      only: physics_buffer_desc

    implicit none

    type(physics_state), intent(inout), dimension(begchunk:endchunk) :: phys_state
    type(cam_in_t),      intent(inout), dimension(begchunk:endchunk) :: cam_in
    type(cam_out_t),     intent(inout), dimension(begchunk:endchunk) :: cam_out

    type(physics_buffer_desc), pointer                 :: pbuf2d(:,:)

    !--------------------------------------------------------------------------

  end subroutine phys_timestep_init

  !======================================================================================

end module physpkg
