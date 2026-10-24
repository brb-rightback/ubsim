////////////////////////////////////////////////////////////////////////
/// \file  ExtGenPXSec.cxx
/// \brief See ExtGenPXSec.h
////////////////////////////////////////////////////////////////////////

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>

#include "Framework/Conventions/RefFrame.h"
#include "Framework/Conventions/Units.h"
#include "Framework/Interaction/Interaction.h"
#include "Framework/Messenger/Messenger.h"
#include "Framework/ParticleData/PDGUtils.h"

#include "ubsim/ExtGen/GENIE/ExtGenPXSec.h"

namespace {

// Expand $VAR and ${VAR} with their environment values (unset -> empty).
// TSystem::ExpandPathName is not used: in art, the ROOT error it raises for
// an unset variable becomes a fatal exception that hides our own message.
std::string ExpandEnv(const std::string& in)
{
  std::string out;
  for (size_t i = 0; i < in.size(); ++i) {
    if (in[i] != '$') { out += in[i]; continue; }
    size_t start = i + 1, end;
    if (start < in.size() && in[start] == '{') {
      end = in.find('}', start);
      if (end == std::string::npos) return out + in.substr(i);
      const char* val = std::getenv(in.substr(start + 1, end - start - 1).c_str());
      if (val) out += val;
      i = end;
    } else {
      end = start;
      while (end < in.size() && (std::isalnum(static_cast<unsigned char>(in[end])) || in[end] == '_')) ++end;
      const char* val = std::getenv(in.substr(start, end - start).c_str());
      if (val) out += val;
      i = end - 1;
    }
  }
  return out;
}

} // namespace

namespace genie {
namespace ubext {

//____________________________________________________________________________
ExtGenPXSec::ExtGenPXSec() :
  XSecAlgorithmI("genie::ubext::ExtGenPXSec"),
  fTableLoaded(false)
{
}
//____________________________________________________________________________
ExtGenPXSec::ExtGenPXSec(std::string config) :
  XSecAlgorithmI("genie::ubext::ExtGenPXSec", config),
  fTableLoaded(false)
{
}
//____________________________________________________________________________
ExtGenPXSec::~ExtGenPXSec()
{
}
//____________________________________________________________________________
double ExtGenPXSec::XSec(const Interaction* /*in*/, KinePhaseSpace_t /*kps*/) const
{
  // Only total cross sections are provided; the final state comes from the
  // external generator, never from GENIE kinematics generators.
  throw std::logic_error("genie::ubext::ExtGenPXSec::XSec() called: only "
                         "Integral() is available for external generators");
}
//____________________________________________________________________________
double ExtGenPXSec::Integral(const Interaction* in) const
{
  // GENIE only gets here when the spline file has no spline for this
  // interaction, so name it in any error.
  if (!fTableLoaded) LoadTable(in);

  const InitialState& init = in->InitState();
  const ProcessInfo&  proc = in->ProcInfo();
  const Key key(init.ProbePdg(), proc.IsWeakCC(), init.Tgt().Pdg());

  auto it = fTables.find(key);
  if (it == fTables.end()) {
    std::ostringstream msg;
    msg << "genie::ubext::ExtGenPXSec: no spline in the spline file (XSecTable) and"
        << " no entry in the table " << fTablePath << " for interaction "
        << in->AsString() << " (nu " << init.ProbePdg()
        << (proc.IsWeakCC() ? " CC" : " NC") << " on target " << init.Tgt().Pdg()
        << "). GENIE needs a spline for every nucleus of every material in the"
        << " whole geometry and every flux flavour.";
    std::cerr << msg.str() << std::endl;  // art may not show the exception text
    throw std::runtime_error(msg.str());
  }

  // Splines are normally all in the spline file; report every interaction
  // that has to fall back to the table (std::cerr, since GENIE's own
  // messages are silenced in production mode).
  if (fReported.insert(in->AsString()).second) {
    std::cerr << "genie::ubext::ExtGenPXSec: no spline for " << in->AsString()
              << ", computing it from the table " << fTablePath << std::endl;
  }

  const Table& tab = it->second;
  const double E = init.ProbeE(kRfLab);
  if (E < tab.front().first || E > tab.back().first) return 0.;

  auto hi = std::lower_bound(tab.begin(), tab.end(), std::make_pair(E, 0.));
  if (hi == tab.begin()) return tab.front().second * 1e-38 * units::cm2;
  auto lo = hi - 1;
  const double f = (E - lo->first) / (hi->first - lo->first);
  const double sigma = lo->second + f * (hi->second - lo->second);

  return sigma * 1e-38 * units::cm2;
}
//____________________________________________________________________________
bool ExtGenPXSec::ValidProcess(const Interaction* in) const
{
  const ProcessInfo& proc = in->ProcInfo();
  return (proc.IsWeakCC() || proc.IsWeakNC()) &&
         pdg::IsNeutralLepton(in->InitState().ProbePdg());
}
//____________________________________________________________________________
void ExtGenPXSec::Configure(const Registry& config)
{
  Algorithm::Configure(config);
  this->LoadConfig();
}
//____________________________________________________________________________
void ExtGenPXSec::Configure(std::string config)
{
  Algorithm::Configure(config);
  this->LoadConfig();
}
//____________________________________________________________________________
void ExtGenPXSec::LoadConfig()
{
  // The table is only read if GENIE ever needs a cross section that is not
  // in the spline file, so production jobs do not need to ship it.
  GetParamDef("ExtGen-XSecTable", fTablePath, std::string(""));
  fTableLoaded = false;
  fTables.clear();
}
//____________________________________________________________________________
void ExtGenPXSec::LoadTable(const Interaction* missing) const
{
  fTables.clear();

  const std::string path = ExpandEnv(fTablePath);
  std::ifstream in(path);
  if (path.empty() || !in.is_open()) {
    std::ostringstream msg;
    msg << "genie::ubext::ExtGenPXSec: no spline in the spline file (XSecTable) for"
        << " interaction " << missing->AsString()
        << " and no cross section table to compute it from (ExtGen-XSecTable '"
        << fTablePath << "' -> '" << path << "'). GENIE needs a spline for every"
        << " nucleus of every material in the whole geometry and every flux flavour.";
    std::cerr << msg.str() << std::endl;  // art may not show the exception text
    throw std::runtime_error(msg.str());
  }

  std::string line;
  while (std::getline(in, line)) {
    const auto hash = line.find('#');
    if (hash != std::string::npos) line.erase(hash);
    std::istringstream ss(line);
    int nu = 0, tgt = 0;
    std::string current;
    double E = 0., sigma = 0.;
    if (!(ss >> nu >> current >> tgt >> E >> sigma)) continue;
    if (current != "CC" && current != "NC") {
      throw std::runtime_error("genie::ubext::ExtGenPXSec: bad current '" +
                               current + "' in " + path);
    }
    fTables[Key(nu, current == "CC", tgt)].emplace_back(E, sigma);
  }

  for (auto& kv : fTables) std::sort(kv.second.begin(), kv.second.end());

  LOG("ExtGenPXSec", pNOTICE) << "Loaded " << fTables.size()
                              << " cross section tables from " << path;
  fTableLoaded = true;
}

} // namespace ubext
} // namespace genie
