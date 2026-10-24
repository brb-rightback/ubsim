////////////////////////////////////////////////////////////////////////
/// \file  ExtGenPXSec.h
/// \brief Total CC/NC cross sections of an external neutrino generator
///        (GiBUU, ...) exposed to GENIE, so that GENIE's flux and
///        geometry drivers choose interactions with the external
///        generator's rates.
///
/// Only Integral() is meaningful. GENIE normally takes these cross
/// sections from the spline file (XSecTable); Integral() is only called
/// when a spline is missing (gmkspl, or a nucleus/flavour that the spline
/// file does not cover). In that case the text table named by the
/// "ExtGen-XSecTable" parameter is read; any initial state not in the
/// table is a fatal error, so missing targets can never silently get a
/// zero cross section.
///
/// Table format (one point per line, '#' starts a comment):
///   nu_pdg  current(CC|NC)  target_pdg  E[GeV]  sigma[1e-38 cm^2 per nucleus]
/// sigma is linearly interpolated in E and is zero outside the tabulated
/// range of each (nu_pdg, current, target_pdg) entry.
////////////////////////////////////////////////////////////////////////
#ifndef UBSIM_EXTGEN_EXTGENPXSEC_H
#define UBSIM_EXTGEN_EXTGENPXSEC_H

#include <map>
#include <set>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

#include "Framework/EventGen/XSecAlgorithmI.h"

namespace genie {
namespace ubext {

class ExtGenPXSec : public XSecAlgorithmI {
public:
  ExtGenPXSec();
  ExtGenPXSec(std::string config);
  virtual ~ExtGenPXSec();

  // XSecAlgorithmI interface
  double XSec        (const Interaction* in, KinePhaseSpace_t kps) const override;
  double Integral    (const Interaction* in) const override;
  bool   ValidProcess(const Interaction* in) const override;

  void Configure(const Registry& config) override;
  void Configure(std::string config) override;

private:
  // (nu_pdg, is_cc, target_pdg)
  using Key = std::tuple<int, bool, int>;
  // (E [GeV], sigma [1e-38 cm^2 per nucleus]), sorted in E
  using Table = std::vector<std::pair<double, double>>;

  void LoadConfig();
  void LoadTable(const Interaction* missing) const;

  std::string fTablePath;

  mutable bool fTableLoaded;
  mutable std::map<Key, Table> fTables;
  mutable std::set<std::string> fReported;  // interactions computed from the table
};

} // namespace ubext
} // namespace genie

#endif // UBSIM_EXTGEN_EXTGENPXSEC_H
