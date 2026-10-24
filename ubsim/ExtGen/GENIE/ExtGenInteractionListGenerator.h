////////////////////////////////////////////////////////////////////////
/// \file  ExtGenInteractionListGenerator.h
/// \brief One CC and one NC interaction per (neutrino, target) initial
///        state, for use with an external neutrino generator.
///
/// GENIE only decides whether, where and in which current a neutrino
/// interacts; the interaction mode (QE, MEC, RES, DIS, ...) is decided by
/// the external generator, so the scattering type is left as kScNull.
/// For free-nucleon targets (hydrogen) the struck nucleon is set, as GENIE
/// requires for those targets.
////////////////////////////////////////////////////////////////////////
#ifndef UBSIM_EXTGEN_EXTGENINTERACTIONLISTGENERATOR_H
#define UBSIM_EXTGEN_EXTGENINTERACTIONLISTGENERATOR_H

#include <string>

#include "Framework/EventGen/InteractionListGeneratorI.h"

namespace genie {
namespace ubext {

class ExtGenInteractionListGenerator : public InteractionListGeneratorI {
public:
  ExtGenInteractionListGenerator();
  ExtGenInteractionListGenerator(std::string config);
  ~ExtGenInteractionListGenerator();

  InteractionList* CreateInteractionList(const InitialState& init) const override;

  void Configure(const Registry& config) override;
  void Configure(std::string config) override;
};

} // namespace ubext
} // namespace genie

#endif // UBSIM_EXTGEN_EXTGENINTERACTIONLISTGENERATOR_H
