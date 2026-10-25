# GiBUU: build script (offline) and the converter of GiBUU's request-mode
# output to the served-event format (run in grid jobs, step C).
cet_make_exec( extgen_gibuu_convert
               SOURCE extgen_gibuu_convert.cc
               LIBRARIES ubsim_ExtGen_Modules
                         cetlib_except
                         ${ROOT_BASIC_LIB_LIST}
                         ${ROOT_PHYSICS}
             )

install_source()
