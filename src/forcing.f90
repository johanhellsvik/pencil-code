! $Id: forcing.f90,v 1.123 2007-10-04 12:02:13 ajohan Exp $

module Forcing

!  Module for forcing in the Navier-Stokes equation
!  (or, in special cases, in the entropy equation).

  use Cdata
  use General
  use Messages

  implicit none

  include 'record_types.h'
  include 'forcing.h'

  real :: force=0.,force2=0.
  real :: relhel=1.,height_ff=0.,r_ff=0.,fountain=1.,width_ff=.5
  real :: dforce=0.,radius_ff,k1_ff=1.,slope_ff=0.,work_ff=0.
  real :: omega_ff=1.
  real :: tforce_stop=impossible,tforce_stop2=impossible
  real :: tforce_start=0.,tforce_start2=0.
  real :: wff_ampl=0.,xff_ampl=0.,zff_ampl=0.,zff_hel=0.,max_force=impossible
  real :: dtforce=0., dtforce_duration=-1.0, force_strength=0.
  real, dimension(3) :: force_direction=(/0.,0.,0./)
  real, dimension(3) :: location_fixed=(/0.,0.,0./)
  real, dimension(nx) :: profx_ampl=1.,profx_hel=1.
  real, dimension(mz) :: profz_ampl=1.,profz_hel=0. !(initialize profz_hel=1)
  integer :: kfountain=5,ifff,iffx,iffy,iffz
  logical :: lwork_ff=.false.,lmomentum_ff=.false.
  logical :: lmagnetic_forcing=.false.,ltestfield_forcing=.false.
  logical :: lhelical_test=.false.,lrandom_location=.true.
  logical :: lscale_kvector_tobox=.false.,lwrite_gausspot_to_file=.true.
  logical :: old_forcing_evector=.false.
  character (len=labellen) :: iforce='zero', iforce2='zero'
  character (len=labellen) :: iforce_profile='nothing'
  integer :: Legendrel
  real ::  Bessel_alpha,fpre
! For helical forcing in sphreical polar coordinate system
  real,allocatable,dimension(:,:,:) :: psif
! Persistent stuff
  real :: tsforce=-10.
  real, dimension (3) :: location

  integer :: dummy              ! We cannot define empty namelists
  namelist /forcing_init_pars/ dummy

  namelist /forcing_run_pars/ &
       tforce_start,tforce_start2,&
       iforce,force,relhel,height_ff,r_ff,width_ff, &
       iforce2,force2,kfountain,fountain,tforce_stop,tforce_stop2, &
       dforce,radius_ff,k1_ff,slope_ff,work_ff,lmomentum_ff, &
       omega_ff,location_fixed,lrandom_location,lwrite_gausspot_to_file, &
       wff_ampl,xff_ampl,zff_ampl,zff_hel, &
       lmagnetic_forcing,ltestfield_forcing, &
       max_force,dtforce,dtforce_duration,old_forcing_evector, &
       iforce_profile,lscale_kvector_tobox, &
       force_direction, force_strength, &
       Legendrel,Bessel_alpha,lhelical_test,fpre

  ! other variables (needs to be consistent with reset list below)
  integer :: idiag_rufm=0, idiag_ufm=0, idiag_ofm=0, idiag_ffm=0
  integer :: idiag_fxbxm=0, idiag_fxbym=0, idiag_fxbzm=0

  contains

!***********************************************************************
    subroutine register_forcing()
!
!  add forcing in timestep()
!  11-may-2002/wolf: coded
!
      use Cdata
      use Mpicomm
      use Sub
!
      logical, save :: first=.true.
!
      if (.not. first) call stop_it('register_forcing: called twice')
      first = .false.
!
      lforcing = .true.
!
!  identify version number
!
      if (lroot) call cvs_id( &
           "$Id: forcing.f90,v 1.123 2007-10-04 12:02:13 ajohan Exp $")
!
    endsubroutine register_forcing
!***********************************************************************
    subroutine initialize_forcing(lstarting)
!
!  read seed field parameters
!  nothing done from start.f90 (lstarting=.true.)
!
      use Cdata
      use Sub, only: inpui
!
      logical, save :: first=.true.
      logical :: lstarting
!
      if (lstarting) then
        if(ip<4) print*,'initialize_forcing: not needed in start'
      else
!
!  check whether we want ordinary hydro forcing or magnetic forcing
!
        if (lmagnetic_forcing) then
          ifff=iaa; iffx=iax; iffy=iay; iffz=iaz
        else
          ifff=iuu; iffx=iux; iffy=iuy; iffz=iuz
        endif
        if (ldebug) print*,'initialize_forcing: ifff=',ifff
!
!  check whether we want constant forcing at each timestep,
!  in which case lwork_ff is set to true.
!
        if(work_ff/=0.) then
          force=1.
          lwork_ff=.true.
          if(lroot) print*,'initialize_forcing: reset force=1., because work_ff is set'
        endif
      endif
!
!  vertical profiles for amplitude and helicity of the forcing
!  default is constant profiles for rms velocity and helicity.
!
      if (iforce_profile=='nothing') then
        profx_ampl=1.; profx_hel=1.
        profz_ampl=1.; profz_hel=1.
      elseif (iforce_profile=='equator') then
        profx_ampl=1.; profx_hel=1.
        profz_ampl=1.
        do n=1,mz
          profz_hel(n)=sin(z(n))
        enddo
      elseif (iforce_profile=='intensity') then
        profx_ampl=1.; profx_hel=1.
        profz_hel=1.
        do n=1,mz
          profz_ampl(n)=.5+.5*cos(z(n))
        enddo
      elseif (iforce_profile=='galactic') then
        profx_ampl=1.; profx_hel=1.
        do n=1,mz
          if(abs(z(n))<zff_ampl) profz_ampl(n)=.5*(1.-cos(z(n)))
          if(abs(z(n))<zff_hel ) profz_hel (n)=.5*(1.+cos(z(n)/2.))
        enddo
      elseif (iforce_profile=='diffrot_corona') then
        profz_ampl=1.; profz_hel=1.
        profx_ampl=.5*(1.-tanh((x(l1:l2)-xff_ampl)/wff_ampl))
        profx_hel=1.
      endif
!
    endsubroutine initialize_forcing
!***********************************************************************
    subroutine addforce(f)
!
!  add forcing at the end of each time step
!  Since forcing is constant during one time step,
!  this can be added as an Euler 1st order step
!
      use Cdata
!
      real, dimension (mx,my,mz,mfarray) :: f
!
      logical, save :: lfirstforce=.true., lfirstforce2=.true.
      logical, save :: llastforce=.true., llastforce2=.true.
!
!  Turn off forcing if t<tforce_start or t>tforce_stop.
!  This can be useful for producing good initial conditions
!  for turbulent decay experiments.
!
      if ( (t>tforce_stop) .or. (t<tforce_start) ) then
        if ( (t>tforce_stop) .and. llastforce .and. lroot) &
            print*, 'addforce: t>tforce_stop; no forcing'
        if (t>tforce_stop) llastforce=.false.
      else
        if ( iforce/='zero' .and. lfirstforce .and. lroot ) &
            print*, 'addforce: addforce started'
        lfirstforce=.false.
!
!  calculate and add forcing function
!
        select case(iforce)
        case ('zero'); if (headt) print*,'addforce: No forcing'
        case ('irrotational');  call forcing_irro(f,force)
        case ('helical', '2');  call forcing_hel(f)
        case ('GP');            call forcing_GP(f)
        case ('TG');            call forcing_TG(f)
        case ('ABC');           call forcing_ABC(f)
        case ('nocos');         call forcing_nocos(f)
        case ('fountain', '3'); call forcing_fountain(f)
        case ('horiz-shear');   call forcing_hshear(f)
        case ('twist');         call forcing_twist(f)
        case ('diffrot');       call forcing_diffrot(f,force)
        case ('blobs');         call forcing_blobs(f)
        case ('gaussianpot');   call forcing_gaussianpot(f,force)
        case ('hel_smooth');    call forcing_hel_smooth(f)
        case ('hel_sp');        call forcing_hel_sp(f)
        case default; if(lroot) print*,'addforce: No such forcing iforce=',trim(iforce)
        endselect
      endif
!
!  add *additional* forcing function
!
      if ( (t>tforce_stop2) .or. (t<tforce_start2) ) then
        if ( (t>tforce_stop2) .and. llastforce2 .and. lroot) &
            print*,'addforce: t>tforce_stop2; no forcing'
        if (t>tforce_stop2) llastforce2=.false.
      else
        if ( (iforce2/='zero') .and. lfirstforce2 .and. lroot) &
            print*, 'addforce: addforce2 started'
        lfirstforce2=.false.
!
        select case(iforce2)
        case ('zero'); if(headtt .and. lroot) print*,'addforce: No additional forcing'
        case ('irrotational'); call forcing_irro(f,force2)
        case ('helical');      call forcing_hel(f)
        case ('fountain');     call forcing_fountain(f)
        case ('horiz-shear');  call forcing_hshear(f)
        case ('diffrot');      call forcing_diffrot(f,force2)
        case default; if(lroot) print*,'addforce: No such forcing iforce2=',trim(iforce2)
        endselect
!
        if (headtt.or.ldebug) print*,'addforce: done addforce'
      endif
!
    endsubroutine addforce
!***********************************************************************
    subroutine forcing_irro(f,force_ampl)
!
!  add acoustic forcing function, using a set of precomputed wavevectors
!  This forcing drives pressure waves
!
!  10-sep-01/axel: coded
!
      use Mpicomm
      use Cdata
!
      real, dimension (mx,my,mz,mfarray) :: f
      real :: force_ampl
!
      real :: phase,ffnorm
      real, save :: kav
      real, dimension (2) :: fran
      complex, dimension (mx) :: fx
      complex, dimension (my) :: fy
      complex, dimension (mz) :: fz
      complex, dimension (3) :: ikk
      logical, dimension (3), save :: extent
      integer, parameter :: mk=3000
      integer, dimension(mk), save :: kkx,kky,kkz
      integer, save :: ifirst,nk
      integer :: ik,j,jf
!
      if (ifirst==0) then
        if (lroot) print*,'forcing_irro: opening k.dat'
        open(9,file='k.dat')
        read(9,*) nk,kav
        if (lroot) print*,'forcing_irro: average k=',kav
        if(nk.gt.mk) then
          if (lroot) print*,'forcing_irro: dimension mk in forcing_irro is insufficient'
          print*,'nk=',nk,'mk=',mk
          call mpifinalize
        end if
        read(9,*) (kkx(ik),ik=1,nk)
        read(9,*) (kky(ik),ik=1,nk)
        read(9,*) (kkz(ik),ik=1,nk)
        close(9)
        extent(1)=nx.ne.1
        extent(2)=ny.ne.1
        extent(3)=nz.ne.1
      endif
      ifirst=ifirst+1
!
      call random_number_wrapper(fran)
      phase=pi*(2*fran(1)-1.)
      ik=nk*.9999*fran(2)+1
      if (ip<=6) print*,'forcing_irro: ik,phase,kk=',ik,phase,kkx(ik),kky(ik),kkz(ik),dt,ifirst
!
!  need to multiply by dt (for Euler step), but it also needs to be
!  divided by sqrt(dt), because square of forcing is proportional
!  to a delta function of the time difference
!
      ffnorm=force_ampl*sqrt(kav/dt)*dt
      fx=exp(cmplx(0.,kkx(ik)*x+phase))*ffnorm
      fy=exp(cmplx(0.,kky(ik)*y))
      fz=exp(cmplx(0.,kkz(ik)*z))
!
      ikk(1)=cmplx(0.,kkx(ik))
      ikk(2)=cmplx(0.,kky(ik))
      ikk(3)=cmplx(0.,kkz(ik))
!
      do j=1,3
        if(extent(j)) then
          jf=j+ifff-1
          do n=n1,n2
          do m=m1,m2
            f(l1:l2,m,n,jf)=f(l1:l2,m,n,jf)+real(ikk(j)*fx(l1:l2)*fy(m)*fz(n))
          enddo
          enddo
        endif
      enddo
!
    endsubroutine forcing_irro
!***********************************************************************
    subroutine forcing_hel(f)
!
!  Add helical forcing function, using a set of precomputed wavevectors.
!  The relative helicity of the forcing function is determined by the factor
!  sigma, called here also relhel. If it is +1 or -1, the forcing is a fully
!  helical Beltrami wave of positive or negative helicity. For |relhel| < 1
!  the helicity less than maximum. For relhel=0 the forcing is nonhelical.
!  The forcing function is now normalized to unity (also for |relhel| < 1).
!
!  10-apr-00/axel: coded
!   3-sep-02/axel: introduced k1_ff, to rescale forcing function if k1/=1.
!  25-sep-02/axel: preset force_ampl to unity (in case slope is not controlled)
!   9-nov-02/axel: corrected normalization factor for the case |relhel| < 1.
!
      use Mpicomm
      use Cdata
      use General
      use Sub
      use EquationOfState, only: cs0
      use Hydro
!
      real :: phase,ffnorm,irufm
      real, save :: kav
      real, dimension (1) :: fsum_tmp,fsum
      real, dimension (2) :: fran
      real, dimension (nx) :: radius,tmpx,rho1,ff,ruf,uf,of,rho
      real, dimension (mz) :: tmpz
      real, dimension (nx,3) :: variable_rhs,forcing_rhs,force_all,uu,oo,bb,fxb
      real, dimension (nx,3) :: fda
      real, dimension (mx,my,mz,mfarray) :: f
      complex, dimension (mx) :: fx
      complex, dimension (my) :: fy
      complex, dimension (mz) :: fz
      real, dimension (3) :: coef1,coef2
      logical, dimension (3), save :: extent
      integer, parameter :: mk=3000
      integer, dimension(mk), save :: kkx,kky,kkz
      integer, save :: ifirst=0,nk
      integer :: ik,j,jf,l
      real :: kx0,kx,ky,kz,k2,k,force_ampl=1.
      real :: ex,ey,ez,kde,sig=1.,fact,kex,key,kez,kkex,kkey,kkez
      real, dimension(3) :: e1,e2,ee,kk
      real :: norm,phi
      real :: fd,fd2,kkfd
!
!  additional stuff for test fields
!
      integer :: jtest
!
      if (ifirst==0) then
        if (lroot) print*,'forcing_hel: opening k.dat'
        open(9,file='k.dat')
        read(9,*) nk,kav
        if (lroot) print*,'forcing_hel: average k=',kav
        if(nk.gt.mk) then
          if (lroot) print*,'forcing_hel: mk in forcing_hel is set too small'
          print*,'nk=',nk,'mk=',mk
          call mpifinalize
        end if
        read(9,*) (kkx(ik),ik=1,nk)
        read(9,*) (kky(ik),ik=1,nk)
        read(9,*) (kkz(ik),ik=1,nk)
        close(9)
        extent(1)=nx.ne.1
        extent(2)=ny.ne.1
        extent(3)=nz.ne.1
      endif
      ifirst=ifirst+1
!
!  generate random coefficients -1 < fran < 1
!  ff=force*Re(exp(i(kx+phase)))
!  |k_i| < akmax
!
      call random_number_wrapper(fran)
      phase=pi*(2*fran(1)-1.)
      ik=nk*(.9999*fran(2))+1
      if(ip<=6) print*,'forcing_hel: ik,phase=',ik,phase
      if(ip<=6) print*,'forcing_hel: kx,ky,kz=',kkx(ik),kky(ik),kkz(ik)
      if(ip<=6) print*,'forcing_hel: dt, ifirst=',dt,ifirst
!
!  normally we want to use the wavevectors as the are,
!  but in some cases, e.g. when the box is bigger than 2pi,
!  we want to rescale k so that k=1 now corresponds to a smaller value.
!
      if (lscale_kvector_tobox) then
        kx0=kkx(ik)*(2.*pi/Lxyz(1))
        ky=kky(ik)*(2.*pi/Lxyz(2))
        kz=kkz(ik)*(2.*pi/Lxyz(3))
      else
        kx0=kkx(ik)
        ky=kky(ik)
        kz=kkz(ik)
      endif
!
!  in the shearing sheet approximation, kx = kx0 - St*k_y.
!  Here, St=-deltay/Lx
!
      if (Sshear==0.) then
        kx=kx0
      else
        kx=kx0+ky*deltay/Lx
      endif
!
      if(headt.or.ip<5) print*, 'forcing_hel: kx0,kx,ky,kz=',kx0,kx,ky,kz
      k2=kx**2+ky**2+kz**2
      k=sqrt(k2)
!
! Find e-vector
!
      !
      ! Start with old method (not isotropic) for now.
      ! Pick e1 if kk not parallel to ee1. ee2 else.
      !
      if((ky.eq.0).and.(kz.eq.0)) then
        ex=0; ey=1; ez=0
      else
        ex=1; ey=0; ez=0
      endif
      if (.not. old_forcing_evector) then
        !
        !  Isotropize ee in the plane perp. to kk by
        !  (1) constructing two basis vectors for the plane perpendicular
        !      to kk, and
        !  (2) choosing a random direction in that plane (angle phi)
        !  Need to do this in order for the forcing to be isotropic.
        !
        kk = (/kx, ky, kz/)
        ee = (/ex, ey, ez/)
        call cross(kk,ee,e1)
        call dot2(e1,norm); e1=e1/sqrt(norm) ! e1: unit vector perp. to kk
        call cross(kk,e1,e2)
        call dot2(e2,norm); e2=e2/sqrt(norm) ! e2: unit vector perp. to kk, e1
        call random_number_wrapper(phi); phi = phi*2*pi
        ee = cos(phi)*e1 + sin(phi)*e2
        ex=ee(1); ey=ee(2); ez=ee(3)
      endif
!
!  k.e
!
      call dot(kk,ee,kde)
!
!  k x e
!
      kex=ky*ez-kz*ey
      key=kz*ex-kx*ez
      kez=kx*ey-ky*ex
!
!  k x (k x e)
!
      kkex=ky*kez-kz*key
      kkey=kz*kex-kx*kez
      kkez=kx*key-ky*kex
!
!  ik x (k x e) + i*phase
!
!  Normalize ff; since we don't know dt yet, we finalize this
!  within timestep where dt is determined and broadcast.
!
!  This does already include the new sqrt(2) factor (missing in B01).
!  So, in order to reproduce the 0.1 factor mentioned in B01
!  we have to set force=0.07.
!
!  Furthermore, for |relhel| < 1, sqrt(2) should be replaced by
!  sqrt(1.+relhel**2). This is done now (9-nov-02).
!  This means that the previous value of force=0.07 (for relhel=0)
!  should now be replaced by 0.05.
!
!  Note: kav is not to be scaled with k1_ff (forcing should remain
!  unaffected when changing k1_ff).
!
      ffnorm=sqrt(1.+relhel**2) &
        *k*sqrt(k2-kde**2)/sqrt(kav*cs0**3)*(k/kav)**slope_ff
      if (ip.le.9) print*,'forcing_hel: k,kde,ffnorm,kav=',k,kde,ffnorm,kav
      if (ip.le.9) print*,'forcing_hel: k*sqrt(k2-kde**2)=',k*sqrt(k2-kde**2)
!
!  need to multiply by dt (for Euler step), but it also needs to be
!  divided by sqrt(dt), because square of forcing is proportional
!  to a delta function of the time difference
!
      fact=force/ffnorm*sqrt(dt)
!
!  The wavevector is for the case where Lx=Ly=Lz=2pi. If that is not the
!  case one needs to scale by 2pi/Lx, etc.
!
      fx=exp(cmplx(0.,kx*k1_ff*x+phase))*fact
      fy=exp(cmplx(0.,ky*k1_ff*y))
      fz=exp(cmplx(0.,kz*k1_ff*z))
!
!  possibly multiply forcing by z-profile
!  (This stuff is now supposed to be done in initialize; keep for now)
!
      if (height_ff/=0.) then
        if (lroot .and. ifirst==1) print*,'forcing_hel: include z-profile'
        tmpz=(z/height_ff)**2
        fz=fz*exp(-tmpz**5/max(1.-tmpz,1e-5))
      endif
!
!  possibly multiply forcing by sgn(z) and radial profile
!
      if (r_ff/=0.) then
        if (lroot .and. ifirst==1) &
             print*,'forcing_hel: applying sgn(z)*xi(r) profile'
        !
        ! only z-dependent part can be done here; radial stuff needs to go
        ! into the loop
        !
        tmpz = tanh(z/width_ff)
        fz = fz*tmpz
      endif
!
      if (ip.le.5) print*,'forcing_hel: fx=',fx
      if (ip.le.5) print*,'forcing_hel: fy=',fy
      if (ip.le.5) print*,'forcing_hel: fz=',fz
!
!  prefactor; treat real and imaginary parts separately (coef1 and coef2),
!  so they can be multiplied by different profiles below.
!
      coef1(1)=k*kex; coef2(1)=relhel*kkex
      coef1(2)=k*key; coef2(2)=relhel*kkey
      coef1(3)=k*kez; coef2(3)=relhel*kkez
      if (ip.le.5) print*,'forcing_hel: coef=',coef1,coef2
!
! An attempt to implement anisotropic forcing using direction
! dependent forcing amplitude. Activated only if force_strength,
! describing the anisotropic part of the forcing, is
! nonzero. force_direction, which is a vector, defines the preferred
! direction of forcing. The expression for the forcing amplitude used
! at the moment is:
!
!  f(i)=f0*[1+epsilon(delta_ij*(k(i)*fd(j))/(|k||fd|))^2*fd(i)/|fd|] 
!
! here f0 and fd are shorthand for force and forcing_direction,
! respectively, and epsilon=force_strength/force.
!
      if (force_strength/=0.) then
         call dot(force_direction,force_direction,fd2)
         fd=sqrt(fd2)
         do j=1,3
            fda(:,j) = 1. + (force_strength/force) &
                 *(kk(j)*force_direction(j)/(k*fd))**2 &
                 *force_direction(j)/fd
         end do
      else
         fda = 1.
      end if
!
!  In the past we always forced the du/dt, but in some cases
!  it may be better to force rho*du/dt (if lmomentum_ff=.true.)
!  For compatibility with earlier results, lmomentum_ff=.false. by default.
!
      if(lmomentum_ff) then
        rho1=exp(-f(l1:l2,m,n,ilnrho))
        rho=1./rho1
      else
        rho1=1.
        rho=exp(f(l1:l2,m,n,ilnrho))
      endif
!
!  loop the two cases separately, so we don't check for r_ff during
!  each loop cycle which could inhibit (pseudo-)vectorisation
!  calculate energy input from forcing; must use lout (not ldiagnos)
!
      irufm=0
      if (r_ff == 0) then       ! no radial profile
        if (lwork_ff) call calc_force_ampl(f,fx,fy,fz,profz_ampl(n)*cmplx(coef1,profz_hel(n)*coef2),force_ampl)
        do n=n1,n2
          do m=m1,m2
            variable_rhs=f(l1:l2,m,n,iffx:iffz)
            do j=1,3
              if(extent(j)) then
                jf=j+ifff-1
                forcing_rhs(:,j)=rho1*profx_ampl*profz_ampl(n)*force_ampl &
                  *real(cmplx(coef1(j),profx_hel*profz_hel(n)*coef2(j)) &
                  *fx(l1:l2)*fy(m)*fz(n))*fda(:,j)
                  if(lhelical_test) then
                    f(l1:l2,m,n,jf)=forcing_rhs(:,j)
                  else
                    f(l1:l2,m,n,jf)=f(l1:l2,m,n,jf)+forcing_rhs(:,j)
                  endif
                if (ltestfield_forcing) then
                  do jtest=1,12
                    iaxtest=iaatest+3*(jtest-1)
                    jf=j+iaxtest-1
                    f(l1:l2,m,n,jf)=f(l1:l2,m,n,jf)+forcing_rhs(:,j)
                  enddo
                endif
              endif
            enddo
          enddo
        enddo
      else                      ! with radial profile
        do j=1,3
          if(extent(j)) then
            jf=j+ifff-1
            do n=n1,n2
              sig = relhel*tmpz(n)
              coef1(1)=cmplx(k*kex,sig*kkex)
              coef1(2)=cmplx(k*key,sig*kkey)
              coef1(3)=cmplx(k*kez,sig*kkez)
              do m=m1,m2
                if(lspherical_coords)then
                  radius = x(l1:l2)
                else
                  radius = sqrt(x(l1:l2)**2+y(m)**2+z(n)**2)
                endif
                tmpx = 0.5*(1.-tanh((radius-r_ff)/width_ff))
                f(l1:l2,m,n,jf)=f(l1:l2,m,n,jf)+rho1*real( &
                  cmplx(coef1(j),coef2(j))*tmpx*fx(l1:l2)*fy(m)*fz(n))
              enddo
            enddo
          endif
        enddo
      endif
      !
      ! For printouts
      !
      if (lout) then
        if (idiag_rufm/=0) then
          uu=f(l1:l2,m,n,iux:iuz)
          call dot(uu,forcing_rhs,uf)
          call sum_mn_name(rho*uf,idiag_rufm)
        endif
        if (idiag_ufm/=0) then
          uu=f(l1:l2,m,n,iux:iuz)
          call dot(uu,forcing_rhs,uf)
          call sum_mn_name(uf,idiag_ufm)
        endif
        if (idiag_ofm/=0) then
          call curl(f,iuu,oo)
          call dot(oo,forcing_rhs,of)
          call sum_mn_name(of,idiag_ofm)
        endif
        if (idiag_ffm/=0) then
          call dot2(forcing_rhs,ff)
          call sum_mn_name(ff,idiag_ffm)
        endif
        if (lmagnetic) then
          if (idiag_fxbxm/=0.or.idiag_fxbym/=0.or.idiag_fxbzm/=0) then
            call curl(f,iaa,bb)
            call cross(forcing_rhs,bb,fxb)
            call sum_mn_name(fxb(:,1),idiag_fxbxm)
            call sum_mn_name(fxb(:,2),idiag_fxbym)
            call sum_mn_name(fxb(:,3),idiag_fxbzm)
          endif
        endif
      endif
!
      if (ip.le.9) print*,'forcing_hel: forcing OK'
!
    endsubroutine forcing_hel
!***********************************************************************
    subroutine forcing_hel_sp(f)
!
!  Add helical forcing function in spherical polar coordinate system. 
!  25-jul-07/dhruba: adapted from forcing_hel
!
      use Mpicomm
      use Cdata
      use General
      use Sub
      use EquationOfState, only: cs0
      use Hydro
!      use SpecialFunctions
!
      real :: phase,ffnorm,irufm
      integer, save :: ifirst
      real, dimension(3) :: ee
      real, dimension(nx,3) :: capitalT,capitalS,capitalH,psi
      real, dimension(nx,3,3) :: psi_ij,Tij
      real, dimension (mx,my,mz,mfarray) :: f
      integer ::l,emm,iread,j,jf,mmin,mmax
      complex :: psi_ell_m
      real :: a_ell,anum,adenom,jlm,ylm,rphase,fnorm,alphar
      real :: rz, Plmreal, Plmimag,ran_min,ran_max
      real, dimension(mx) :: Z_psi
      real,dimension(my) :: Pl
! -----------------------------------------
      if (ifirst==0) then
        if (lroot) print*,'Helical forcing in spherical polar coordinate'
        if (lroot) print*,'allocating psif ..'
        allocate(psif(mx,my,mz))
        if (lroot) print*, '..done'
! Now calculate the "potential" for the helical forcing. The expression
! is taken from Chandrasekhar and Kendall.
! Now construct the Z_psi(r) 
        call sp_bessely_l(anum,Legendrel,Bessel_alpha*x(l1))
        call sp_besselj_l(adenom,Legendrel,Bessel_alpha*x(l1))
        a_ell = -anum/adenom
!        write(*,*) 'dhruba:',anum,adenom,Legendrel,Bessel_alpha,x(l1)
        do l=l1-nghost,l2+nghost
          alphar = Bessel_alpha*x(l)
          call sp_besselj_l(jlm,Legendrel,alphar)
          call sp_bessely_l(ylm,Legendrel,alphar)
          Z_psi(l) = (a_ell*jlm+ylm)
        enddo
        do m=m1-nghost,m2+nghost
          call legendre_pl(Pl(m),Legendrel,y(m))
        enddo
!-------
        do n=n1-nghost,n2+nghost
          do m=m1-nghost,m2+nghost
            do l=l1-nghost,l2+nghost
              psif(l,m,n) = Z_psi(l)*Pl(m)
            enddo
          enddo
        enddo
        ifirst= ifirst+1
        write(*,*) 'dhruba: first time in hel_sp'
      else
      endif
! ----- Now calculate the force from the potential and add this to
! velocity
! get a random unit vector with three components ee_r, ee_theta, ee_phi
! psi at present is just Z_{ell}^m. We next do a sum over random coefficients 
! get random psi. 

!      write(*,*) 'mmin=',mmin
!! ----------now generate and add the force ------------
      call random_number_wrapper(rz)
      ee(3) = rz
      call random_number_wrapper(rphase)
      rphase = PI*rphase
      ee(1) = sqrt(1-rz*rz)*cos(rphase)
      ee(2) = sqrt(1-rz*rz)*sin(rphase)
      fnorm = fpre*cs0*sqrt(Bessel_alpha*cs0)
 !     write(*,*) 'dhruba:',fnorm*sqrt(dt),dt,ee(1),ee(2),ee(3)
      do n=n1,n2
        do m=m1,m2
          psi(:,1) = psif(l1:l2,m,n)*ee(1)
          psi(:,2) = psif(l1:l2,m,n)*ee(2)
          psi(:,3) = psif(l1:l2,m,n)*ee(3)
          call gij_psi(psif,ee,psi_ij)
          call curl_mn(psi_ij,capitalT,psi)
          call gij_psi_etc(psif,ee,psi,psi_ij,Tij)
          call curl_mn(Tij,capitalS,capitalT)
          capitalS = (1./Bessel_alpha)*capitalS
          capitalH = capitalT + capitalS
          do j=1,3
            jf = iuu+j-1
            if(lhelical_test) then
              f(l1:l2,m,n,jf) = capitalH(:,j)
            else
! stochastic euler scheme of integration 
           f(l1:l2,m,n,jf) = f(l1:l2,m,n,jf)+ fnorm*capitalH(:,j)*sqrt(dt)
          endif
          enddo
        enddo
      enddo
 
      
    endsubroutine forcing_hel_sp
!***********************************************************************
    subroutine forcing_GP(f)
!
!  Add Galloway-Proctor forcing function.
!
!  24-jul-06/axel: coded
!
      use Mpicomm
      use Cdata
      use General
      use Sub
      use Hydro
!
      real :: phase,ffnorm,irufm
      real, save :: kav
      real, dimension (1) :: fsum_tmp,fsum
      real, dimension (2) :: fran
      real, dimension (nx) :: radius,tmpx,ruf,rho
      real, dimension (mz) :: tmpz
      real, dimension (nx,3) :: variable_rhs,forcing_rhs,force_all
      real, dimension (mx,my,mz,mfarray) :: f
      real, dimension (mx) :: cosx,sinx
      real :: cost,sint,cosym,sinym
      logical, dimension (3), save :: extent
      integer, save :: ifirst
      integer :: ik,j,jf
      real :: force_ampl=1.,fact
!
      if(ip<=6) print*,'forcing_GP: t=',t
      cost=cos(omega_ff*t)
      sint=sin(omega_ff*t)
!
!  Normalize ff; since we don't know dt yet, we finalize this
!  within timestep where dt is determined and broadcast.
!
!  need to multiply by dt (for Euler step), but it also needs to be
!  divided by sqrt(dt), because square of forcing is proportional
!  to a delta function of the time difference
!
      fact=sqrt(1.5)*force*sqrt(dt)
!
!  loop the two cases separately, so we don't check for r_ff during
!  each loop cycle which could inhibit (pseudo-)vectorisation
!  calculate energy input from forcing; must use lout (not ldiagnos)
!
      irufm=0
      do m=m1,m2
        cosx=cos(k1_ff*x+cost)
        sinx=sin(k1_ff*x+cost)
        cosym=cos(k1_ff*y(m)+sint)
        sinym=sin(k1_ff*y(m)+sint)
        forcing_rhs(:,1)=-fact*sinym
        forcing_rhs(:,2)=-fact*cosx(l1:l2)
        forcing_rhs(:,3)=+fact*(sinx(l1:l2)+cosym)
        do n=n1,n2
          variable_rhs=f(l1:l2,m,n,iffx:iffz)
          do j=1,3
            jf=j+ifff-1
            f(l1:l2,m,n,jf)=f(l1:l2,m,n,jf)+forcing_rhs(:,j)
          enddo
          if (lout) then
            if (idiag_rufm/=0) then
              rho=exp(f(l1:l2,m,n,ilnrho))
              call multsv_mn(rho/dt,forcing_rhs,force_all)
              call dot_mn(variable_rhs,force_all,ruf)
              irufm=irufm+sum(ruf)
            endif
          endif
        enddo
      enddo
      !
      ! For printouts
      !
      if (lout) then
        if (idiag_rufm/=0) then
          irufm=irufm/(nwgrid)
          !
          !  on different processors, irufm needs to be communicated
          !  to other processors
          !
          fsum_tmp(1)=irufm
          call mpireduce_sum(fsum_tmp,fsum,1)
          irufm=fsum(1)
          call mpibcast_real(irufm,1)
          !
          fname(idiag_rufm)=irufm
          itype_name(idiag_rufm)=ilabel_sum
        endif
      endif
!
      if (ip<=9) print*,'forcing_GP: forcing OK'
!
    endsubroutine forcing_GP
!***********************************************************************
    subroutine forcing_TG(f)
!
!  Add Taylor-Green forcing function.
!
!   9-oct-04/axel: coded
!
      use Mpicomm
      use Cdata
      use General
      use Sub
      use Hydro
!
      real :: phase,ffnorm,irufm
      real, save :: kav
      real, dimension (1) :: fsum_tmp,fsum
      real, dimension (2) :: fran
      real, dimension (nx) :: radius,tmpx,ruf,rho
      real, dimension (mz) :: tmpz
      real, dimension (nx,3) :: variable_rhs,forcing_rhs,force_all
      real, dimension (mx,my,mz,mfarray) :: f
      real, dimension (mx), save :: sinx,cosx
      real, dimension (my), save :: siny,cosy
      real, dimension (mz), save :: cosz
      logical, dimension (3), save :: extent
      integer, save :: ifirst
      integer :: ik,j,jf
      real :: force_ampl=1.,fact
!
      if (ifirst==0) then
        if (lroot) print*,'forcing_TG: calculate sinx,cosx,siny,cosy,cosz'
        sinx=sin(k1_ff*x)
        cosx=cos(k1_ff*x)
        siny=sin(k1_ff*y)
        cosy=cos(k1_ff*y)
        cosz=cos(k1_ff*z)
        extent(1)=nx.ne.1
        extent(2)=ny.ne.1
        extent(3)=nz.ne.1
      endif
      ifirst=ifirst+1
!
      if(ip<=6) print*,'forcing_TG: dt, ifirst=',dt,ifirst
!
!  Normalize ff; since we don't know dt yet, we finalize this
!  within timestep where dt is determined and broadcast.
!
!  need to multiply by dt (for Euler step), but it also needs to be
!  divided by sqrt(dt), because square of forcing is proportional
!  to a delta function of the time difference
!
      fact=2*force*sqrt(dt)
!
!  loop the two cases separately, so we don't check for r_ff during
!  each loop cycle which could inhibit (pseudo-)vectorisation
!  calculate energy input from forcing; must use lout (not ldiagnos)
!
      irufm=0
      do n=n1,n2
        do m=m1,m2
          variable_rhs=f(l1:l2,m,n,iffx:iffz)
          forcing_rhs(:,1)=+fact*sinx(l1:l2)*cosy(m)*cosz(n)
          forcing_rhs(:,2)=-fact*cosx(l1:l2)*siny(m)*cosz(n)
          forcing_rhs(:,3)=0.
          do j=1,3
            if(extent(j)) then
              jf=j+ifff-1
              f(l1:l2,m,n,jf)=f(l1:l2,m,n,jf)+forcing_rhs(:,j)
            endif
          enddo
          if (lout) then
            if (idiag_rufm/=0) then
              rho=exp(f(l1:l2,m,n,ilnrho))
              call multsv_mn(rho/dt,forcing_rhs,force_all)
              call dot_mn(variable_rhs,force_all,ruf)
              irufm=irufm+sum(ruf)
            endif
          endif
        enddo
      enddo
      !
      ! For printouts
      !
      if (lout) then
        if (idiag_rufm/=0) then
          irufm=irufm/(nwgrid)
          !
          !  on different processors, irufm needs to be communicated
          !  to other processors
          !
          fsum_tmp(1)=irufm
          call mpireduce_sum(fsum_tmp,fsum,1)
          irufm=fsum(1)
          call mpibcast_real(irufm,1)
          !
          fname(idiag_rufm)=irufm
          itype_name(idiag_rufm)=ilabel_sum
        endif
      endif
!
      if (ip<=9) print*,'forcing_TG: forcing OK'
!
    endsubroutine forcing_TG
!***********************************************************************
    subroutine forcing_ABC(f)
!
!  Added ABC forcing function
!
!  17-jul-06/axel: coded
!
      use Mpicomm
      use Cdata
      use General
      use Sub
      use Hydro
!
      real, dimension (mx,my,mz,mfarray) :: f
!
      real :: phase,ffnorm,irufm
      real, save :: kav
      real, dimension (1) :: fsum_tmp,fsum
      real, dimension (2) :: fran
      real, dimension (nx) :: radius,tmpx,ruf,rho
      real, dimension (mz) :: tmpz
      real, dimension (nx,3) :: variable_rhs,forcing_rhs,force_all,bb,fxb
      real, dimension (mx), save :: sinx,cosx
      real, dimension (my), save :: siny,cosy
      real, dimension (mz), save :: sinz,cosz
      integer, save :: ifirst
      integer :: ik,j,jf
      real :: force_ampl=1.,fact
!
!  at the first step, the sin and cos functions are calculated for all
!  x,y,z points and are then saved and used for all subsequent steps
!  and pencils
!
      if(ip<=6) print*,'forcing_ABC: ifirst=',ifirst
      if (ifirst==0) then
        if (lroot) print*,'forcing_ABC: calculate sinx,cosx,siny,cosy,sinz,cosz'
        sinx=sin(k1_ff*x); cosx=cos(k1_ff*x)
        siny=sin(k1_ff*y); cosy=cos(k1_ff*y)
        sinz=sin(k1_ff*z); cosz=cos(k1_ff*z)
      endif
      ifirst=ifirst+1
      if(ip<=6) print*,'forcing_ABC: dt, ifirst=',dt,ifirst
!
!  Normalize ff; since we don't know dt yet, we finalize this
!  within timestep where dt is determined and broadcast.
!
!  need to multiply by dt (for Euler step), but it also needs to be
!  divided by sqrt(dt), because square of forcing is proportional
!  to a delta function of the time difference
!
      fact=2*force*sqrt(dt)
!
!  loop the two cases separately, so we don't check for r_ff during
!  each loop cycle which could inhibit (pseudo-)vectorisation
!  calculate energy input from forcing; must use lout (not ldiagnos)
!
      irufm=0
      do n=n1,n2
        do m=m1,m2
          variable_rhs=f(l1:l2,m,n,iffx:iffz)
          forcing_rhs(:,1)=fact*(sinz(n    )+cosy(m)    )
          forcing_rhs(:,2)=fact*(sinx(l1:l2)+cosz(n)    )
          forcing_rhs(:,3)=fact*(siny(m    )+cosx(l1:l2))
          do j=1,3
            jf=j+ifff-1
            f(l1:l2,m,n,jf)=f(l1:l2,m,n,jf)+forcing_rhs(:,j)
          enddo
          if (lout) then
            if (idiag_rufm/=0) then
              rho=exp(f(l1:l2,m,n,ilnrho))
              call multsv_mn(rho/dt,forcing_rhs,force_all)
              call dot_mn(variable_rhs,force_all,ruf)
              irufm=irufm+sum(ruf)
            endif
          endif
        enddo
      enddo
      !
      ! For printouts
      !
      if (lout) then
        if (idiag_rufm/=0) then
          irufm=irufm/(nwgrid)
          !
          !  on different processors, irufm needs to be communicated
          !  to other processors
          !
          fsum_tmp(1)=irufm
          call mpireduce_sum(fsum_tmp,fsum,1)
          irufm=fsum(1)
          call mpibcast_real(irufm,1)
          !
          fname(idiag_rufm)=irufm
          itype_name(idiag_rufm)=ilabel_sum
        endif
        if (lmagnetic) then
          if (idiag_fxbxm/=0.or.idiag_fxbym/=0.or.idiag_fxbzm/=0) then
            call curl(f,iaa,bb)
            call cross(forcing_rhs,bb,fxb)
            call sum_mn_name(fxb(:,1),idiag_fxbxm)
            call sum_mn_name(fxb(:,2),idiag_fxbym)
            call sum_mn_name(fxb(:,3),idiag_fxbzm)
          endif
        endif
      endif
!
      if (ip<=9) print*,'forcing_ABC: forcing OK'
!
    endsubroutine forcing_ABC
!***********************************************************************
    subroutine forcing_nocos(f)
!
!  Add no-cosine forcing function.
!
!  27-oct-04/axel: coded
!
      use Mpicomm
      use Cdata
      use General
      use Sub
      use Hydro
!
      real :: phase,ffnorm,irufm
      real, save :: kav
      real, dimension (1) :: fsum_tmp,fsum
      real, dimension (2) :: fran
      real, dimension (nx) :: radius,tmpx,ruf,rho
      real, dimension (mz) :: tmpz
      real, dimension (nx,3) :: variable_rhs,forcing_rhs,force_all
      real, dimension (mx,my,mz,mfarray) :: f
      real, dimension (mx), save :: sinx
      real, dimension (my), save :: siny
      real, dimension (mz), save :: sinz
      logical, dimension (3), save :: extent
      integer, save :: ifirst
      integer :: ik,j,jf
      real :: force_ampl=1.,fact
!
      if (ifirst==0) then
        if (lroot) print*,'forcing_nocos: calculate sinx,siny,sinz'
        sinx=sin(k1_ff*x)
        siny=sin(k1_ff*y)
        sinz=sin(k1_ff*z)
        extent(1)=nx.ne.1
        extent(2)=ny.ne.1
        extent(3)=nz.ne.1
      endif
      ifirst=ifirst+1
!
      if(ip<=6) print*,'forcing_hel: dt, ifirst=',dt,ifirst
!
!  Normalize ff; since we don't know dt yet, we finalize this
!  within timestep where dt is determined and broadcast.
!
!  need to multiply by dt (for Euler step), but it also needs to be
!  divided by sqrt(dt), because square of forcing is proportional
!  to a delta function of the time difference
!
      fact=force*sqrt(dt)
!
!  loop the two cases separately, so we don't check for r_ff during
!  each loop cycle which could inhibit (pseudo-)vectorisation
!  calculate energy input from forcing; must use lout (not ldiagnos)
!
      irufm=0
      do n=n1,n2
        do m=m1,m2
          variable_rhs=f(l1:l2,m,n,iffx:iffz)
          forcing_rhs(:,1)=fact*sinz(n)
          forcing_rhs(:,2)=fact*sinx(l1:l2)
          forcing_rhs(:,3)=fact*siny(m)
          do j=1,3
            if(extent(j)) then
              jf=j+ifff-1
              f(l1:l2,m,n,jf)=f(l1:l2,m,n,jf)+forcing_rhs(:,j)
            endif
          enddo
          if (lout) then
            if (idiag_rufm/=0) then
              rho=exp(f(l1:l2,m,n,ilnrho))
              call multsv_mn(rho/dt,forcing_rhs,force_all)
              call dot_mn(variable_rhs,force_all,ruf)
              irufm=irufm+sum(ruf)
            endif
          endif
        enddo
      enddo
      !
      ! For printouts
      !
      if (lout) then
        if (idiag_rufm/=0) then
          irufm=irufm/(nwgrid)
          !
          !  on different processors, irufm needs to be communicated
          !  to other processors
          !
          fsum_tmp(1)=irufm
          call mpireduce_sum(fsum_tmp,fsum,1)
          irufm=fsum(1)
          call mpibcast_real(irufm,1)
          !
          fname(idiag_rufm)=irufm
          itype_name(idiag_rufm)=ilabel_sum
        endif
      endif
!
      if (ip.le.9) print*,'forcing_nocos: forcing OK'
!
    endsubroutine forcing_nocos
!***********************************************************************
    subroutine forcing_gaussianpot(f,force_ampl)
!
!  gradient of gaussians as forcing function
!
!  19-dec-05/tony: coded
!
      use Mpicomm
      use Cdata
      use General
      use Sub
      use EquationOfState, only: cs0
      use Hydro
!
      real, dimension (mx,my,mz,mfarray) :: f
      real :: force_ampl
!
      real, dimension (1) :: fsum_tmp,fsum
      real, dimension (3) :: fran
      real, dimension (nx) :: radius2,gaussian,ruf,rho
      real, dimension (nx,3) :: variable_rhs,force_all,delta
      logical, dimension (3), save :: extent
      integer :: ik,j,jf
      real :: irufm,fact,width_ff21
!
!  check length of time step
!
      if(ip<=6) print*,'forcing_gaussianpot: dt=',dt
!
!  check whether there is any extent in each of the three directions
!
      extent(1)=nx.ne.1
      extent(2)=ny.ne.1
      extent(3)=nz.ne.1
!
!  generate random numbers
!
      if (t>tsforce) then
        if (lrandom_location) then
          call random_number_wrapper(fran)
          location=fran*Lxyz+xyz0
        else
          location=location_fixed
        endif
!
        if (lroot .and. lwrite_gausspot_to_file) then
          open(1,file=trim(datadir)//'/gaussian_pot_forcing.dat',status='unknown',position='append')
            write(1,'(4f14.7)') t, location
          close (1)
        endif
!
        tsforce=t+dtforce
        if(ip<=6) print*,'forcing_gaussianpot: location=',location
      endif
!
!  Let explosion last dtforce_duration or, by default, until next explosion.
!
      if ( (dtforce_duration<0.0) .or. &
           (t-(tsforce-dtforce))<=dtforce_duration ) then
!
!  Normalize ff; since we don't know dt yet, we finalize this
!  within timestep where dt is determined and broadcast.
!
!  need to multiply by dt (for Euler step), but it also needs to be
!  divided by sqrt(dt), because square of forcing is proportional
!  to a delta function of the time difference.
!  When dtforce is finite, take dtforce+.5*dt.
!  The 1/2 factor takes care of round-off errors.
!  Also define width_ff21 = 1/width^2
!
        width_ff21=1./width_ff**2
        fact=2.*width_ff21*force_ampl*dt*sqrt(cs0*width_ff/max(dtforce+.5*dt,dt))
!
!  loop the two cases separately, so we don't check for r_ff during
!  each loop cycle which could inhibit (pseudo-)vectorisation
!  calculate energy input from forcing; must use lout (not ldiagnos)
!
        irufm=0
!
!  loop over all pencils
!
        do n=n1,n2
          do m=m1,m2
!
!  Obtain distance to center of blob
!
            delta(:,1)=x(l1:l2)-location(1)
            delta(:,2)=y(m)-location(2)
            delta(:,3)=z(n)-location(3)
            do j=1,3
              if (lperi(j)) then
                where (delta(:,j) >  Lxyz(j)/2.) delta(:,j)=delta(:,j)-Lxyz(j)
                where (delta(:,j) < -Lxyz(j)/2.) delta(:,j)=delta(:,j)+Lxyz(j)
              endif
              if (.not.extent(j)) delta(:,j)=0.
            enddo
!
            radius2=delta(:,1)**2+delta(:,2)**2+delta(:,3)**2
            gaussian=fact*exp(-radius2*width_ff21)
            variable_rhs=f(l1:l2,m,n,iffx:iffz)
            do j=1,3
              if (extent(j)) then
                jf=j+ifff-1
                f(l1:l2,m,n,jf)=f(l1:l2,m,n,jf)+gaussian*delta(:,j)
              endif
            enddo
            if (lout) then
              if (idiag_rufm/=0) then
                rho=exp(f(l1:l2,m,n,ilnrho))
                call multsv_mn(rho/dt,spread(gaussian,2,3)*delta,force_all)
                call dot_mn(variable_rhs,force_all,ruf)
                irufm=irufm+sum(ruf)
              endif
            endif
          enddo
        enddo
      endif
!
!  For printouts
!
      if (lout) then
        if (idiag_rufm/=0) then
          irufm=irufm/(nwgrid)
!
!  on different processors, irufm needs to be communicated
!  to other processors
!
          fsum_tmp(1)=irufm
          call mpireduce_sum(fsum_tmp,fsum,1)
          irufm=fsum(1)
          call mpibcast_real(irufm,1)
!
          fname(idiag_rufm)=irufm
          itype_name(idiag_rufm)=ilabel_sum
        endif
      endif
!
      if (ip<=9) print*,'forcing_nocos: forcing OK'
!
    endsubroutine forcing_gaussianpot
!***********************************************************************
    subroutine calc_force_ampl(f,fx,fy,fz,coef,force_ampl)
!
!  calculates the coefficient for a forcing that satisfies
!  <rho*u*f> = constant.
!
!   7-sep-02/axel: coded
!
      use Cdata
      use Sub
      use Hydro
      use Mpicomm
!
      real, dimension (mx,my,mz,mfarray) :: f
      real, dimension (nx,3) :: uu
      real, dimension (nx) :: rho,udotf
      real, dimension (1) :: fsum_tmp,fsum
      complex, dimension (mx) :: fx
      complex, dimension (my) :: fy
      complex, dimension (mz) :: fz
      complex, dimension (3) :: coef
      real :: rho_uu_ff,force_ampl
      integer :: j
!
      rho_uu_ff=0.
      do n=n1,n2
        do m=m1,m2
          rho=exp(f(l1:l2,m,n,ilnrho))
          uu=f(l1:l2,m,n,iffx:iffz)
          udotf=0.
          do j=1,3
            udotf=udotf+uu(:,j)*real(coef(j)*fx(l1:l2)*fy(m)*fz(n))
          enddo
          rho_uu_ff=rho_uu_ff+sum(rho*udotf)
        enddo
      enddo
!
!  on different processors, this result needs to be communicated
!  to other processors
!
      fsum_tmp(1)=rho_uu_ff
      call mpireduce_sum(fsum_tmp,fsum,1)
      if(lroot) rho_uu_ff=fsum(1)/(ncpus*nw)
!      if(lroot) rho_uu_ff=rho_uu_ff/(ncpus*nw)
      call mpibcast_real(rho_uu_ff,1)
!
!  scale forcing function
!  but do this only when rho_uu_ff>0.; never allow it to change sign
!

!print*,fname(idiag_urms)

        if(headt) print*,'calc_force_ampl: divide forcing function by rho_uu_ff=',rho_uu_ff
        !      force_ampl=work_ff/(.1+max(0.,rho_uu_ff))
        force_ampl=work_ff/rho_uu_ff
        if (force_ampl .gt. max_force) force_ampl=max_force
        if (force_ampl .lt. -max_force) force_ampl=-max_force
!
    endsubroutine calc_force_ampl
!***********************************************************************
    subroutine forcing_hel_noshear(f)
!
!  add helical forcing function, using a set of precomputed wavevectors
!
!  10-apr-00/axel: coded
!
      use Mpicomm
      use Cdata
      use General
      use Sub
      use EquationOfState, only: cs0
      use Hydro
!
      real :: phase,ffnorm
      real, save :: kav
      real, dimension (2) :: fran
      real, dimension (nx) :: radius,tmpx
      real, dimension (mz) :: tmpz
      real, dimension (mx,my,mz,mfarray) :: f
      complex, dimension (mx) :: fx
      complex, dimension (my) :: fy
      complex, dimension (mz) :: fz
      complex, dimension (3) :: coef
      integer, parameter :: mk=3000
      integer, dimension(mk), save :: kkx,kky,kkz
      integer, save :: ifirst,nk
      integer :: ik,j,jf,kx,ky,kz,kex,key,kez,kkex,kkey,kkez
      real :: k2,k,ex,ey,ez,kde,sig=1.,fact
      real, dimension(3) :: e1,e2,ee,kk
      real :: norm,phi
!
      if (ifirst==0) then
        if (lroot) print*,'force_hel_noshear: opening k.dat'
        open(9,file='k.dat')
        read(9,*) nk,kav
        if (lroot) print*,'force_hel_noshear: average k=',kav
        if(nk.gt.mk) then
          if (lroot) print*,'force_hel_noshear: dimension mk in forcing_hel is insufficient'
          print*,'nk=',nk,'mk=',mk
          call mpifinalize
        end if
        read(9,*) (kkx(ik),ik=1,nk)
        read(9,*) (kky(ik),ik=1,nk)
        read(9,*) (kkz(ik),ik=1,nk)
        close(9)
      endif
      ifirst=ifirst+1
!
!  generate random coefficients -1 < fran < 1
!  ff=force*Re(exp(i(kx+phase)))
!  |k_i| < akmax
!
      call random_number_wrapper(fran)
      phase=pi*(2*fran(1)-1.)
      ik=nk*.9999*fran(2)+1
      if (ip<=6) print*,'force_hel_noshear: ik,phase,kk=',ik,phase,kkx(ik),kky(ik),kkz(ik),dt,ifirst
!
      kx=kkx(ik)
      ky=kky(ik)
      kz=kkz(ik)
      if(ip.le.4) print*, 'force_hel_noshear: kx,ky,kz=',kx,ky,kz
!
      k2=float(kx**2+ky**2+kz**2)
      k=sqrt(k2)
!
! Find e-vector
!
      !
      ! Start with old method (not isotropic) for now.
      ! Pick e1 if kk not parallel to ee1. ee2 else.
      !
      if((ky.eq.0).and.(kz.eq.0)) then
        ex=0; ey=1; ez=0
      else
        ex=1; ey=0; ez=0
      endif
      if (.not. old_forcing_evector) then
        !
        !  Isotropize ee in the plane perp. to kk by
        !  (1) constructing two basis vectors for the plane perpendicular
        !      to kk, and
        !  (2) choosing a random direction in that plane (angle phi)
        !  Need to do this in order for the forcing to be isotropic.
        !
        kk = (/kx, ky, kz/)
        ee = (/ex, ey, ez/)
        call cross(kk,ee,e1)
        call dot2(e1,norm); e1=e1/sqrt(norm) ! e1: unit vector perp. to kk
        call cross(kk,e1,e2)
        call dot2(e2,norm); e2=e2/sqrt(norm) ! e2: unit vector perp. to kk, e1
        call random_number_wrapper(phi); phi = phi*2*pi
        ee = cos(phi)*e1 + sin(phi)*e2
        ex=ee(1); ey=ee(2); ez=ee(3)
      endif
!
!  k.e
!
      call dot(kk,ee,kde)
!
!  k x e
!
      kex=ky*ez-kz*ey
      key=kz*ex-kx*ez
      kez=kx*ey-ky*ex
!
!  k x (k x e)
!
      kkex=ky*kez-kz*key
      kkey=kz*kex-kx*kez
      kkez=kx*key-ky*kex
!
!  ik x (k x e) + i*phase
!
!  Normalise ff; since we don't know dt yet, we finalize this
!  within timestep where dt is determined and broadcast.
!
!  This does already include the new sqrt(2) factor (missing in B01).
!  So, in order to reproduce the 0.1 factor mentioned in B01
!  we have to set force=0.07.
!
      ffnorm=sqrt(2.)*k*sqrt(k2-kde**2)/sqrt(kav*cs0**3)
      if (ip.le.12) print*,'force_hel_noshear: k,kde,ffnorm,kav,dt,cs0=',k,kde,ffnorm,kav,dt,cs0
      if (ip.le.12) print*,'force_hel_noshear: k*sqrt(k2-kde**2)=',k*sqrt(k2-kde**2)
      !!(debug...) write(21,'(f10.4,3i3,f7.3)') t,kx,ky,kz,phase
!
!  need to multiply by dt (for Euler step), but it also needs to be
!  divided by sqrt(dt), because square of forcing is proportional
!  to a delta function of the time difference
!
      fact=force/ffnorm*sqrt(dt)
!
!  The wavevector is for the case where Lx=Ly=Lz=2pi. If that is not the
!  case one needs to scale by 2pi/Lx, etc.
!
      fx=exp(cmplx(0.,2*pi/Lx*kx*x+phase))*fact
      fy=exp(cmplx(0.,2*pi/Ly*ky*y))
      fz=exp(cmplx(0.,2*pi/Lz*kz*z))
!
!  possibly multiply forcing by z-profile
!
      if (height_ff/=0.) then
        if (lroot .and. ifirst==1) print*,'forcing_hel_noshear: include z-profile'
        tmpz=(z/height_ff)**2
        fz=fz*exp(-tmpz**5/max(1.-tmpz,1e-5))
      endif
!
!  possibly multiply forcing by sgn(z) and radial profile
!
      if (r_ff/=0.) then
        if (lroot .and. ifirst==1) &
             print*,'forcing_hel_noshear: applying sgn(z)*xi(r) profile'
        !
        ! only z-dependent part can be done here; radial stuff needs to go
        ! into the loop
        !
        tmpz = tanh(z/width_ff)
        fz = fz*tmpz
      endif
!
      if (ip.le.5) print*,'force_hel_noshear: fx=',fx
      if (ip.le.5) print*,'force_hel_noshear: fy=',fy
      if (ip.le.5) print*,'force_hel_noshear: fz=',fz
!
!  prefactor
!
      sig=relhel
      coef(1)=cmplx(k*float(kex),sig*float(kkex))
      coef(2)=cmplx(k*float(key),sig*float(kkey))
      coef(3)=cmplx(k*float(kez),sig*float(kkez))
      if (ip.le.5) print*,'force_hel_noshear: coef=',coef
!
! loop the two cases separately, so we don't check for r_ff during
! each loop cycle which could inhibit (pseudo-)vectorisation
!
      if (r_ff == 0) then       ! no radial profile
        do j=1,3
          jf=j+ifff-1
          do n=n1,n2
            do m=m1,m2
              f(l1:l2,m,n,jf) = &
                   f(l1:l2,m,n,jf)+real(coef(j)*fx(l1:l2)*fy(m)*fz(n))
            enddo
          enddo
        enddo
      else                      ! with radial profile
        do j=1,3
          jf=j+ifff-1
          do n=n1,n2
            sig = relhel*tmpz(n)
            coef(1)=cmplx(k*float(kex),sig*float(kkex))
            coef(2)=cmplx(k*float(key),sig*float(kkey))
            coef(3)=cmplx(k*float(kez),sig*float(kkez))
            do m=m1,m2
              radius = sqrt(x(l1:l2)**2+y(m)**2+z(n)**2)
              tmpx = 0.5*(1.-tanh((radius-r_ff)/width_ff))
              f(l1:l2,m,n,jf) = &
                   f(l1:l2,m,n,jf) + real(coef(j)*tmpx*fx(l1:l2)*fy(m)*fz(n))
            enddo
          enddo
        enddo
      endif
!
      if (ip.le.12) print*,'force_hel_noshear: forcing OK'
!
    endsubroutine forcing_hel_noshear
!***********************************************************************
    subroutine forcing_roberts(f)
!
!  add some artificial fountain flow
!  (to check for example small scale magnetic helicity loss)
!
!  30-may-02/axel: coded
!
      use Mpicomm
      use Cdata
!
      real, dimension (mx,my,mz,mfarray) :: f
      real, dimension (nx) :: sxx,cxx
      real, dimension (mx) :: sx,cx
      real, dimension (my) :: sy,cy
      real, dimension (mz) :: sz,cz,tmpz,gz,gg,ss=1.,gz1
      real :: kx,ky,kz,ffnorm,fac
!
!  identify ourselves
!
      if (headtt.or.ldebug) print*,'forcing_roberts: ENTER'
!
!  need to multiply by dt (for Euler step), but it also needs to be
!  divided by sqrt(dt), because square of forcing is proportional
!  to a delta function of the time difference
!
      kx=kfountain
      ky=kfountain
      kz=1.
!
      sx=sin(kx*x); cx=cos(kx*x)
      sy=sin(ky*y); cy=cos(ky*y)
      sz=sin(kz*z); cz=cos(kz*z)
!
!  abbreviation
!
      sxx=sx(l1:l2)
      cxx=cx(l1:l2)
!
!  g(z) and g'(z)
!  use z-profile to cut off
!
      if (height_ff/=0.) then
        tmpz=(z/height_ff)**2
        gz=sz*exp(-tmpz**5/max(1.-tmpz,1e-5))
      endif
!
      fac=1./(60.*dz)
      gg(1:3)=0.; gg(mz-2:mz)=0. !!(border pts to zero)
      gg(4:mz-3)=fac*(45.*(gz(5:mz-2)-gz(3:mz-4)) &
                      -9.*(gz(6:mz-1)-gz(2:mz-5)) &
                         +(gz(7:mz)  -gz(1:mz-6)))
!
!  make sign antisymmetric
!
      where(z<0) ss=-1.
      gz1=-ss*gz !!(negative for z>0)
!
!AB: removed nu dependence here. This whole routine is probably not
!AB: needed at the moment, because it is superseded by continuous forcing
!AB: in hydro.f90
!
      !ffnorm=fountain*nu*dt
      ffnorm=fountain*dt
!
!  set forcing function
!
      do n=n1,n2
      do m=m1,m2
        f(l1:l2,m,n,iffx)=f(l1:l2,m,n,iffx)+ffnorm*(+sxx*cy(m)*gz1(n)+cxx*sy(m)*gg(n))
        f(l1:l2,m,n,iffy)=f(l1:l2,m,n,iffy)+ffnorm*(-cxx*sy(m)*gz1(n)+sxx*cy(m)*gg(n))
        f(l1:l2,m,n,iffz)=f(l1:l2,m,n,iffz)+ffnorm*sxx*sy(m)*gz(n)*2.
      enddo
      enddo
!
    endsubroutine forcing_roberts
!***********************************************************************
    subroutine forcing_fountain(f)
!
!  add some artificial fountain flow
!  (to check for example small scale magnetic helicity loss)
!
!  30-may-02/axel: coded
!
      use Mpicomm
      use Cdata
!
      real, dimension (mx,my,mz,mfarray) :: f
      real, dimension (nx) :: sxx,cxx
      real, dimension (mx) :: sx,cx
      real, dimension (my) :: sy,cy
      real, dimension (mz) :: sz,cz,tmpz,gz,gg,ss=1.,gz1
      real :: kx,ky,kz,ffnorm,fac
!
!  identify ourselves
!
      if (headtt.or.ldebug) print*,'forcing_fountain: ENTER'
!
!  need to multiply by dt (for Euler step), but it also needs to be
!  divided by sqrt(dt), because square of forcing is proportional
!  to a delta function of the time difference
!
      kx=kfountain
      ky=kfountain
      kz=1.
!
      sx=sin(kx*x); cx=cos(kx*x)
      sy=sin(ky*y); cy=cos(ky*y)
      sz=sin(kz*z); cz=cos(kz*z)
!
!  abbreviation
!
      sxx=sx(l1:l2)
      cxx=cx(l1:l2)
!
!  g(z) and g'(z)
!  use z-profile to cut off
!
      if (height_ff/=0.) then
        tmpz=(z/height_ff)**2
        gz=sz*exp(-tmpz**5/max(1.-tmpz,1e-5))
      endif
!
      fac=1./(60.*dz)
      gg(1:3)=0.; gg(mz-2:mz)=0. !!(border pts to zero)
      gg(4:mz-3)=fac*(45.*(gz(5:mz-2)-gz(3:mz-4)) &
                      -9.*(gz(6:mz-1)-gz(2:mz-5)) &
                         +(gz(7:mz)  -gz(1:mz-6)))
!
!  make sign antisymmetric
!
      where(z<0) ss=-1.
      gz1=-ss*gz !!(negative for z>0)
!
!AB: removed nu dependence here. This whole routine is probably not
!AB: needed at the moment, because it should be superseded by continuous
!AB: forcing in hydro.f90
!
      !ffnorm=fountain*nu*kfountain**2*dt
      ffnorm=fountain*kfountain**2*dt
!
!  set forcing function
!
      do n=n1,n2
      do m=m1,m2
        f(l1:l2,m,n,iffx)=f(l1:l2,m,n,iffx)+ffnorm*(cxx*sy(m)*gg(n))
        f(l1:l2,m,n,iffy)=f(l1:l2,m,n,iffy)+ffnorm*(sxx*cy(m)*gg(n))
        f(l1:l2,m,n,iffz)=f(l1:l2,m,n,iffz)+ffnorm*sxx*sy(m)*gz(n)*2.
      enddo
      enddo
!
    endsubroutine forcing_fountain
!***********************************************************************
    subroutine forcing_hshear(f)
!
!  add horizontal shear
!
!  19-jun-02/axel+bertil: coded
!
      use Mpicomm
      use Cdata
!
      real, dimension (mx,my,mz,mfarray) :: f
      real, dimension (nx) :: fx
      real, dimension (mz) :: fz
      real :: kx,ffnorm
!
!  need to multiply by dt (for Euler step).
!  Define fz with ghost zones, so fz(n) is the correct position
!  Comment: Brummell et al have a polynomial instead!
!
      kx=2*pi/Lx
      fx=cos(kx*x(l1:l2))
      fz=1./cosh(z/width_ff)**2
      ffnorm=force*dt  !(dt for the timestep)
!
!  add to velocity (here only y-component)
!
      do n=n1,n2
      do m=m1,m2
        f(l1:l2,m,n,iuy)=f(l1:l2,m,n,iuy)+ffnorm*fx*fz(n)
      enddo
      enddo
!
    endsubroutine forcing_hshear
!***********************************************************************
    subroutine forcing_twist(f)
!
!  add circular twisting motion, (ux, 0, uz)
!
!  19-jul-02/axel: coded
!
      use Mpicomm
      use Cdata
!
      real, dimension (mx,my,mz,mfarray) :: f
      real, dimension (nx,nz) :: xx,zz,r2,tmp,fx,fz
      real :: ffnorm,ry2,fy,ytwist1,ytwist2
!
!  identifier
!
      if(headt) print*,'forcing_twist: r_ff,width_ff=',r_ff,width_ff
!
!  need to multiply by dt (for Euler step).
!
      ffnorm=force*dt  !(dt for the timestep)
!
!  add to velocity
!  calculate r2=(x^2+z^2)/r^2
!
      xx=spread(x(l1:l2),2,nz)
      zz=spread(z(n1:n2),1,nx)
      if (r_ff==0.) then
        if(lroot) print*,'forcing_twist: division by r_ff=0!!'
      endif
      r2=(xx**2+zz**2)/r_ff**2
      tmp=exp(-r2/max(1.-r2,1e-5))*ffnorm
      fx=-zz*tmp
      fz=+xx*tmp
!
!  have opposite twists at
!
      y0=xyz0(2)
      ytwist1=y0+0.25*Ly
      ytwist2=y0+0.75*Ly
!
      do m=m1,m2
        !
        ! first twister
        !
        ry2=((y(m)-ytwist1)/width_ff)**2
        fy=exp(-ry2/max(1.-ry2,1e-5))
        f(l1:l2,m,n1:n2,iffx)=f(l1:l2,m,n1:n2,iffx)+fy*fx
        f(l1:l2,m,n1:n2,iffz)=f(l1:l2,m,n1:n2,iffz)+fy*fz
        !
        ! second twister
        !
        ry2=((y(m)-ytwist2)/width_ff)**2
        fy=exp(-ry2/max(1.-ry2,1e-5))
        f(l1:l2,m,n1:n2,iffx)=f(l1:l2,m,n1:n2,iffx)-fy*fx
        f(l1:l2,m,n1:n2,iffz)=f(l1:l2,m,n1:n2,iffz)-fy*fz
      enddo
!
    endsubroutine forcing_twist
!***********************************************************************
    subroutine forcing_diffrot(f,force_ampl)
!
!  add differential rotation
!
!  26-jul-02/axel: coded
!
      use Mpicomm
      use Cdata
!
      real, dimension (mx,my,mz,mfarray) :: f
      real, dimension (nx,nz) :: fx,fz,tmp
      real :: force_ampl,ffnorm,ffnorm2
!
!  identifier
!
      if(headt) print*,'forcing_diffrot: ENTER'
!
!  need to multiply by dt (for Euler step).
!
      ffnorm=force_ampl*dt  !(dt for the timestep)
!
!  prepare velocity, Uy=cosx*cosz
!
      fx=spread(cos(x(l1:l2)),2,nz)
      fz=spread(cos(z(n1:n2)),1,nx)
!
!  this forcing term is balanced by diffusion operator;
!  need to multiply by nu*k^2, but k=sqrt(1+1) for the forcing
!
!AB: removed nu dependence here. This whole routine is probably not
!AB: needed at the moment, because it should be superseded by continuous
!AB: forcing in hydro.f90
!
      !ffnorm2=ffnorm*nu*2
      ffnorm2=ffnorm*2
      tmp=ffnorm2*fx*fz
!
!  add
!
      do m=m1,m2
        f(l1:l2,m,n1:n2,iuy)=f(l1:l2,m,n1:n2,iuy)+tmp
      enddo
!
    endsubroutine forcing_diffrot
!***********************************************************************
    subroutine forcing_blobs(f)
!
!  add blobs in entropy every dforce time units
!
!  28-jul-02/axel: coded
!
      !use Mpicomm
      use Cdata
      use Sub
!
      real, dimension (mx,my,mz,mfarray) :: f
      real, save :: tforce=0.
      integer, save :: ifirst=0
      integer, save :: nforce=0
      logical :: lforce
      character (len=5) :: ch
      character (len=135) :: file
!
!  identifier
!
      if(headt) print*,'forcing_blobs: ENTER'
!
!  the last forcing time is recorded in tforce.dat
!
      file=trim(datadir)//'/tforce.dat'
      if (ifirst==0) then
        call read_snaptime(trim(file),tforce,nforce,dforce,t)
        ifirst=1
      endif
!
!  Check whether we want to do forcing at this time.
!
      call update_snaptime(file,tforce,nforce,dforce,t,lforce,ch,ENUM=.true.)
      if (lforce) then
        call blob(force,f,iss,radius_ff,0.,0.,.5)
      endif
!
    endsubroutine forcing_blobs
!***********************************************************************
    subroutine forcing_hel_smooth(f)
!
      use Mpicomm
      use Cdata
      use Hydro
      use Sub
!
      real, dimension (mx,my,mz,mfarray) :: f
      real, dimension (mx,my,mz,3) :: force1,force2,force_vec
      real, dimension (nx) :: ruf,rho
      real, dimension (nx,3) :: variable_rhs,forcing_rhs,force_all
      real :: phase1,phase2,p_weight
      real :: kx01,ky1,kz1,kx02,ky2,kz2
      real :: mulforce_vec=1.,irufm
      real, dimension (1) :: fsum_tmp,fsum
      integer, parameter :: mk=3000
      integer, dimension(mk), save :: kkx,kky,kkz
      integer, save :: ifirst,nk
      integer :: ik1,ik2,ik
      real, save :: kav
!
      if (ifirst==0) then
         if (lroot) print*,'forcing_hel_smooth: opening k.dat'
         open(9,file='k.dat')
         read(9,*) nk,kav
         if (lroot) print*,'forcing_hel_smooth: average k=',kav
         if(nk.gt.mk) then
            if (lroot) print*, &
                 'forcing_hel_smooth: dimension mk in forcing_hel_smooth is insufficient'
            print*,'nk=',nk,'mk=',mk
            call mpifinalize
         end if
         read(9,*) (kkx(ik),ik=1,nk)
         read(9,*) (kky(ik),ik=1,nk)
         read(9,*) (kkz(ik),ik=1,nk)
         close(9)
      endif
      ifirst=ifirst+1
!
!  Re-calculate forcing wave numbers if necessary
!
      !tsforce is set to -10 in cdata.f90. It should also be saved in a file
      !so that it will be read again on restarts.
      if (t .gt. tsforce) then
         if (tsforce .lt. 0) then
            call random_number_wrapper(fran1)
         else
            fran1=fran2
         endif
         call random_number_wrapper(fran2)
         tsforce=t+dtforce
      endif
      phase1=pi*(2*fran1(1)-1.)
      ik1=nk*.9999*fran1(2)+1
      kx01=kkx(ik1)
      ky1=kky(ik1)
      kz1=kkz(ik1)
      phase2=pi*(2*fran2(1)-1.)
      ik2=nk*.9999*fran2(2)+1
      kx02=kkx(ik2)
      ky2=kky(ik2)
      kz2=kkz(ik2)

!
!  Calculate forcing function
!
      call hel_vec(f,kx01,ky1,kz1,phase1,kav,ifirst,force1)
      call hel_vec(f,kx02,ky2,kz2,phase2,kav,ifirst,force2)
!
!  Determine weight parameter
!
      p_weight=(tsforce-t)/dtforce
      force_vec=p_weight*force1+(1-p_weight)*force2
!
! Find energy input
!
      if (lout .or. lwork_ff) then
        if (idiag_rufm/=0 .or. lwork_ff) then
          irufm=0
          do n=n1,n2
            do m=m1,m2
              forcing_rhs=force_vec(l1:l2,m,n,:)
              variable_rhs=f(l1:l2,m,n,iffx:iffz)!-force_vec(l1:l2,m,n,:)
              rho=exp(f(l1:l2,m,n,ilnrho))
              call multsv_mn(rho/dt,forcing_rhs,force_all)
              call dot_mn(variable_rhs,force_all,ruf)
              irufm=irufm+sum(ruf)
              !call sum_mn_name(ruf/(nw*ncpus),idiag_rufm)
            enddo
          enddo
        endif
      endif
      irufm=irufm/(ncpus*nw)
!
! If we want to make energy input constant
!
      if (lwork_ff) then

!
!  on different processors, irufm needs to be communicated
!  to other processors
!
        fsum_tmp(1)=irufm
        call mpireduce_sum(fsum_tmp,fsum,1)
        irufm=fsum(1)
        call mpibcast_real(irufm,1)
!
! What should be added to force_vec in order to make the energy
! input equal to work_ff?
!
        mulforce_vec=work_ff/irufm
        if (mulforce_vec .gt. max_force)  mulforce_vec=max_force
      endif
!
!  Add forcing
!
      f(l1:l2,m1:m2,n1:n2,1:3)= &
           f(l1:l2,m1:m2,n1:n2,1:3)+force_vec(l1:l2,m1:m2,n1:n2,:)*mulforce_vec
!
! Save for printouts
!
      if (lout) then
        if (idiag_rufm/=0) then
          fname(idiag_rufm)=irufm*mulforce_vec
          itype_name(idiag_rufm)=ilabel_sum
        endif
      endif
!
    end subroutine forcing_hel_smooth
!***********************************************************************
    subroutine hel_vec(f,kx0,ky,kz,phase,kav,ifirst,force1)
!
!  Add helical forcing function, using a set of precomputed wavevectors.
!  The relative helicity of the forcing function is determined by the factor
!  sigma, called here also relhel. If it is +1 or -1, the forcing is a fully
!  helical Beltrami wave of positive or negative helicity. For |relhel| < 1
!  the helicity less than maximum. For relhel=0 the forcing is nonhelical.
!  The forcing function is now normalized to unity (also for |relhel| < 1).
!
!  10-apr-00/axel: coded
!   3-sep-02/axel: introduced k1_ff, to rescale forcing function if k1/=1.
!  25-sep-02/axel: preset force_ampl to unity (in case slope is not controlled)
!   9-nov-02/axel: corrected normalization factor for the case |relhel| < 1.
!  17-jan-03/nils: adapted from forcing_hel
!
      use Mpicomm
      use Cdata
      use General
      use Sub
      use EquationOfState, only: cs0
      use Hydro
!
      real, dimension (mx,my,mz,mfarray) :: f
      real :: phase,ffnorm
      real :: kav
      real, dimension (nx) :: radius,tmpx
      real, dimension (mz) :: tmpz
      real, dimension (mx,my,mz,3) :: force1
      complex, dimension (mx) :: fx
      complex, dimension (my) :: fy
      complex, dimension (mz) :: fz
      complex, dimension (3) :: coef
      integer :: j,jf
      integer :: ifirst
      real :: kx0,kx,ky,kz,k2,k,force_ampl=1.
      real :: ex,ey,ez,kde,sig=1.,fact,kex,key,kez,kkex,kkey,kkez
      real, dimension(3) :: e1,e2,ee,kk
      real :: norm,phi
!
!  in the shearing sheet approximation, kx = kx0 - St*k_y.
!  Here, St=-deltay/Lx
!
      if (Sshear==0.) then
        kx=kx0
      else
        kx=kx0+ky*deltay/Lx
      endif
!
      if(headt.or.ip<5) print*, 'hel_vec: kx0,kx,ky,kz=',kx0,kx,ky,kz
      k2=kx**2+ky**2+kz**2
      k=sqrt(k2)
!
! Find e-vector
!
      !
      ! Start with old method (not isotropic) for now.
      ! Pick e1 if kk not parallel to ee1. ee2 else.
      !
      if((ky.eq.0).and.(kz.eq.0)) then
        ex=0; ey=1; ez=0
      else
        ex=1; ey=0; ez=0
      endif
      if (.not. old_forcing_evector) then
        !
        !  Isotropize ee in the plane perp. to kk by
        !  (1) constructing two basis vectors for the plane perpendicular
        !      to kk, and
        !  (2) choosing a random direction in that plane (angle phi)
        !  Need to do this in order for the forcing to be isotropic.
        !
        kk = (/kx, ky, kz/)
        ee = (/ex, ey, ez/)
        call cross(kk,ee,e1)
        call dot2(e1,norm); e1=e1/sqrt(norm) ! e1: unit vector perp. to kk
        call cross(kk,e1,e2)
        call dot2(e2,norm); e2=e2/sqrt(norm) ! e2: unit vector perp. to kk, e1
        call random_number_wrapper(phi); phi = phi*2*pi
        ee = cos(phi)*e1 + sin(phi)*e2
        ex=ee(1); ey=ee(2); ez=ee(3)
      endif
!
!  k.e
!
      call dot(kk,ee,kde)
!
!  k x e
!
      kex=ky*ez-kz*ey
      key=kz*ex-kx*ez
      kez=kx*ey-ky*ex
!
!  k x (k x e)
!
      kkex=ky*kez-kz*key
      kkey=kz*kex-kx*kez
      kkez=kx*key-ky*kex
!
!  ik x (k x e) + i*phase
!
!  Normalize ff; since we don't know dt yet, we finalize this
!  within timestep where dt is determined and broadcast.
!
!  This does already include the new sqrt(2) factor (missing in B01).
!  So, in order to reproduce the 0.1 factor mentioned in B01
!  we have to set force=0.07.
!
!  Furthermore, for |relhel| < 1, sqrt(2) should be replaced by
!  sqrt(1.+relhel**2). This is done now (9-nov-02).
!  This means that the previous value of force=0.07 (for relhel=0)
!  should now be replaced by 0.05.
!
!  Note: kav is not to be scaled with k1_ff (forcing should remain
!  unaffected when changing k1_ff).
!
      ffnorm=sqrt(1.+relhel**2) &
        *k*sqrt(k2-kde**2)/sqrt(kav*cs0**3)*(k/kav)**slope_ff
      if (ip.le.9) print*,'hel_vec: k,kde,ffnorm,kav,dt,cs0=',k,kde, &
                                                        ffnorm,kav,dt,cs0
      if (ip.le.9) print*,'hel_vec: k*sqrt(k2-kde**2)=',k*sqrt(k2-kde**2)
      !!(debug...) write(21,'(f10.4,5f8.2)') t,kx0,kx,ky,kz,phase
!
!  need to multiply by dt (for Euler step), but it also needs to be
!  divided by sqrt(dt), because square of forcing is proportional
!  to a delta function of the time difference
!
      fact=force/ffnorm*sqrt(dt)
!
!  The wavevector is for the case where Lx=Ly=Lz=2pi. If that is not the
!  case one needs to scale by 2pi/Lx, etc.
!
      fx=exp(cmplx(0.,kx*k1_ff*x+phase))*fact
      fy=exp(cmplx(0.,ky*k1_ff*y))
      fz=exp(cmplx(0.,kz*k1_ff*z))
!
!  possibly multiply forcing by z-profile
!
      if (height_ff/=0.) then
        if (lroot .and. ifirst==1) print*,'hel_vec: include z-profile'
        tmpz=(z/height_ff)**2
        fz=fz*exp(-tmpz**5/max(1.-tmpz,1e-5))
      endif
!
!  possibly multiply forcing by sgn(z) and radial profile
!
      if (r_ff/=0.) then
        if (lroot .and. ifirst==1) &
             print*,'hel_vec: applying sgn(z)*xi(r) profile'
        !
        ! only z-dependent part can be done here; radial stuff needs to go
        ! into the loop
        !
        tmpz = tanh(z/width_ff)
        fz = fz*tmpz
      endif
!
      if (ip.le.5) print*,'hel_vec: fx=',fx
      if (ip.le.5) print*,'hel_vec: fy=',fy
      if (ip.le.5) print*,'hel_vec: fz=',fz
!
!  prefactor
!
      coef(1)=cmplx(k*kex,relhel*kkex)
      coef(2)=cmplx(k*key,relhel*kkey)
      coef(3)=cmplx(k*kez,relhel*kkez)
      if (ip.le.5) print*,'hel_vec: coef=',coef
!
! loop the two cases separately, so we don't check for r_ff during
! each loop cycle which could inhibit (pseudo-)vectorisation
!
      if (r_ff == 0) then       ! no radial profile
        if (lwork_ff) call calc_force_ampl(f,fx,fy,fz,coef,force_ampl)
        do j=1,3
          jf=j+ifff-1
          do n=n1,n2
            do m=m1,m2
               force1(l1:l2,m,n,jf) = &
                +force_ampl*real(coef(j)*fx(l1:l2)*fy(m)*fz(n))
            enddo
          enddo
        enddo
      else                      ! with radial profile
        do j=1,3
          jf=j+ifff-1
          do n=n1,n2
            sig = relhel*tmpz(n)
            coef(1)=cmplx(k*kex,sig*kkex)
            coef(2)=cmplx(k*key,sig*kkey)
            coef(3)=cmplx(k*kez,sig*kkez)
            do m=m1,m2
              radius = sqrt(x(l1:l2)**2+y(m)**2+z(n)**2)
              tmpx = 0.5*(1.-tanh((radius-r_ff)/width_ff))
              force1(l1:l2,m,n,jf) =  real(coef(j)*tmpx*fx(l1:l2)*fy(m)*fz(n))
            enddo
          enddo
        enddo
      endif
!
      if (ip.le.9) print*,'hel_vec: forcing OK'
!
    end subroutine hel_vec
!***********************************************************************
    subroutine read_forcing_init_pars(unit,iostat)
      integer, intent(in) :: unit
      integer, intent(inout), optional :: iostat

      if (present(iostat).and.NO_WARN) print*,iostat
      if (NO_WARN) print *,unit
       

    endsubroutine read_forcing_init_pars
!***********************************************************************
    subroutine write_forcing_init_pars(unit)
      integer, intent(in) :: unit

      if (NO_WARN) print *,unit

    endsubroutine write_forcing_init_pars
!***********************************************************************
    subroutine read_forcing_run_pars(unit,iostat)
      integer, intent(in) :: unit
      integer, intent(inout), optional :: iostat

      if (present(iostat)) then
        read(unit,NML=forcing_run_pars,ERR=99, IOSTAT=iostat)
      else
        read(unit,NML=forcing_run_pars,ERR=99)
      endif
!
99    return
    endsubroutine read_forcing_run_pars
!***********************************************************************
    subroutine write_forcing_run_pars(unit)
      integer, intent(in) :: unit

      write(unit,NML=forcing_run_pars)

    endsubroutine write_forcing_run_pars
!***********************************************************************
    subroutine input_persistent_forcing(id,lun,done)
!
!  Read in the stored time of the next SNI
!
!  21-dec-05/tony: coded
!
      use Cdata, only: lroot
!
      integer :: id,lun
      logical :: done
!
      if (id==id_record_FORCING_LOCATION) then
        read (lun) location
        done=.true.
      elseif (id==id_record_FORCING_TSFORCE) then
        read (lun) tsforce
        done=.true.
      endif
      if (lroot) print*,'input_persistent_forcing: ', location,tsforce
!
    endsubroutine input_persistent_forcing
!***********************************************************************
    subroutine output_persistent_forcing(lun)
!
!  Writes out the time of the next SNI
!  This is used, for example, for forcing functions with temporal
!  memory, such as in the paper by Mee & Brandenburg (2006, MNRAS)
!
!  21-dec-05/tony: coded
!
      use Cdata, only: lroot
!
      integer :: lun
!
      if (lroot) then
        if (tsforce>=0.) print*,'output_persistent_forcing: ', location, tsforce
      endif
!
!  write details
!
      write (lun) id_record_FORCING_LOCATION
      write (lun) location
      write (lun) id_record_FORCING_TSFORCE
      write (lun) tsforce
!
    endsubroutine output_persistent_forcing
!***********************************************************************
    subroutine rprint_forcing(lreset,lwrite)
!
!  reads and registers print parameters relevant for hydro part
!
!  26-jan-04/axel: coded
!
      use Cdata
      use Sub
!
      integer :: iname
      logical :: lreset,lwr
      logical, optional :: lwrite
!
      lwr = .false.
      if (present(lwrite)) lwr=lwrite
!
!  reset everything in case of reset
!  (this needs to be consistent with what is defined above!)
!
      if (lreset) then
        idiag_rufm=0; idiag_ufm=0; idiag_ofm=0; idiag_ffm=0
        idiag_fxbxm=0; idiag_fxbym=0; idiag_fxbzm=0
      endif
!
!  iname runs through all possible names that may be listed in print.in
!
      if(lroot.and.ip<14) print*,'rprint_forcing: run through parse list'
      do iname=1,nname
        call parse_name(iname,cname(iname),cform(iname),'rufm',idiag_rufm)
        call parse_name(iname,cname(iname),cform(iname),'ufm',idiag_ufm)
        call parse_name(iname,cname(iname),cform(iname),'ofm',idiag_ofm)
        call parse_name(iname,cname(iname),cform(iname),'ffm',idiag_ffm)
        call parse_name(iname,cname(iname),cform(iname),'fxbxm',idiag_fxbxm)
        call parse_name(iname,cname(iname),cform(iname),'fxbym',idiag_fxbym)
        call parse_name(iname,cname(iname),cform(iname),'fxbzm',idiag_fxbzm)
      enddo
!
!  write column where which forcing variable is stored
!
      if (lwr) then
        write(3,*) 'i_rufm=',idiag_rufm
        write(3,*) 'i_ufm=',idiag_ufm
        write(3,*) 'i_ofm=',idiag_ofm
        write(3,*) 'i_ffm=',idiag_ffm
        write(3,*) 'i_fxbxm=',idiag_fxbxm
        write(3,*) 'i_fxbym=',idiag_fxbym
        write(3,*) 'i_fxbzm=',idiag_fxbzm
      endif
!
    endsubroutine rprint_forcing
!***********************************************************************

endmodule Forcing
