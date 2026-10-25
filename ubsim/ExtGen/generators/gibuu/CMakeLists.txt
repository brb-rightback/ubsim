# GiBUU: the converter of GiBUU's request-mode output to the served-event
# format (step C of grid jobs), and the scripts for GiBUU cards, scans and
# the grid tarball. The scripts find each other (and the energy grid) in the
# directory they are installed in, so they are installed together.
cet_make_exec( extgen_gibuu_convert
               SOURCE extgen_gibuu_convert.cc
               LIBRARIES ubsim_ExtGen_Modules
                         cetlib_except
                         ${ROOT_BASIC_LIB_LIST}
                         ${ROOT_PHYSICS}
             )

cet_script( extgen_gibuu_card.sh extgen_gibuu_scan.sh extgen_gibuu_scan_grid.sh
            extgen_gibuu_serve.sh extgen_gibuu_v3.sh extgen_gibuu_xsec_check.sh
            extgen_gibuu_grid_init.sh
            make_gibuu_tarball.sh
            extgen_gibuu_energies.txt )

install_source()
