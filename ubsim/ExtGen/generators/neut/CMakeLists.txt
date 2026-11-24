# NEUT: the scripts of ExtGen's NEUT route (card, cross-section tables,
# serving, grid jobs, validation, the build and the grid tarball) and the
# source of its driver (neut_extgen.cc). NEUT itself and bin/neut_extgen are
# built outside the release by build_neut.sh (from an unmodified NEUT commit)
# and come in the tarball (make_neut_tarball.sh); they run with their own e26
# ROOT (extgen_neut_run.sh). The scripts find each other, the energy grids and
# neut_extgen.cc in the directory they are installed in, so they are installed
# together.
cet_script( extgen_neut_card.sh extgen_neut_run.sh extgen_neut_serve.sh
            extgen_neut_tables.sh extgen_neut_v3.sh
            extgen_neut_grid_init.sh extgen_neut_grid_continue.sh
            build_neut.sh make_neut_tarball.sh
            extgen_neut_energies.txt extgen_neut_pb_energies.txt neut_extgen.cc )

install_source()
