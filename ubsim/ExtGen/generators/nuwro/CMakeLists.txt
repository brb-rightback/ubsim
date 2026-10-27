# NuWro: the scripts of ExtGen's NuWro route (cards, scans, serving, grid
# jobs, the build and the grid tarball). NuWro itself (bin/nuwro_extgen, NuWro
# branch v08_00_00_br) comes in the tarball (make_nuwro_tarball.sh) and runs
# with its own e26 ROOT/Pythia6 (extgen_nuwro_run.sh). The scripts find each
# other (and the energy grid) in the directory they are installed in, so they
# are installed together.
cet_script( extgen_nuwro_card.sh extgen_nuwro_run.sh extgen_nuwro_scan.sh
            extgen_nuwro_scan_grid.sh extgen_nuwro_serve.sh
            extgen_nuwro_grid_init.sh extgen_nuwro_grid_continue.sh extgen_nuwro_v3.sh
            build_nuwro.sh make_nuwro_tarball.sh
            extgen_nuwro_energies.txt )

install_source()
