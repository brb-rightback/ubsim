////////////////////////////////////////////////////////////////////////
/// \file  ExtGenIO.h
/// \brief Request and served-event files of the ExtGen chain, and the
///        rotation between the generator frame and the detector frame.
///
/// Request file (written by ExtGenRequestDumper), one line per MCTruth:
///   # req_id run subrun event truth_idx nu_pdg ccnc tgt_pdg E_GeV vx vy vz t dx dy dz
///
/// Served-event file (written by the external generator's converter, or by
/// ExtGenTruthServer for the GENIE closure test), one block per request:
///   # extgen-served v1 generator=<name> ...
///   EVENT req_id E_GeV gen_proc simb_mode simb_inttype nparts
///   P status pdg px py pz E          (nparts lines)
/// Momenta in GeV, in the target rest frame with the neutrino along +z.
/// E_GeV must be the request's energy exactly (written with %.17g).
/// Status: 1 = final state, tracked; 2 = final state, not tracked;
/// 11 = struck nucleon (at most one); 15 = nuclear remnant.
/// The first status-1 particle must be the primary lepton.
/// gen_proc is the generator's own process code (bookkeeping only).
////////////////////////////////////////////////////////////////////////
#ifndef UBSIM_EXTGEN_EXTGENIO_H
#define UBSIM_EXTGEN_EXTGENIO_H

#include <cstdio>
#include <map>
#include <string>
#include <tuple>
#include <vector>

#include "TLorentzVector.h"
#include "TRotation.h"
#include "TVector3.h"

namespace ubext {

  struct Request {
    long reqId = -1;
    unsigned int run = 0, subRun = 0, event = 0;
    unsigned long truthIdx = 0;
    int nuPdg = 0;
    bool isCC = false;
    int tgtPdg = 0;
    double E = 0.;
  };

  /// (run, subrun, event, truth_idx)
  using RequestKey = std::tuple<unsigned int, unsigned int, unsigned int, unsigned long>;

  struct RequestFile {
    std::vector<std::string> header;
    std::map<RequestKey, Request> requests;
  };

  /// Reads a request file; throws on malformed lines and duplicate keys.
  RequestFile ReadRequests(std::string const& path);

  struct ServedParticle {
    int status = 0;
    int pdg = 0;
    TLorentzVector p4;
  };

  struct ServedEvent {
    long reqId = -1;
    double E = 0.;
    long genProc = 0;
    int mode = 0;
    int intType = 0;
    std::vector<ServedParticle> particles;
  };

  struct ServedFile {
    std::vector<std::string> header;
    std::map<long, ServedEvent> events;  ///< by req_id
  };

  /// Reads a served-event file; throws on malformed blocks and duplicate
  /// req_ids. Particle rules (lepton first, ...) are checked by the merge.
  ServedFile ReadServed(std::string const& path);

  /// Writes one served-event block (used by ExtGenTruthServer).
  void WriteServedEvent(FILE* out, ServedEvent const& ev);

  /// Rotation taking the generator frame (neutrino along +z) to the detector
  /// frame with the neutrino along `nuDir`, after a rotation by `phi` about
  /// the neutrino direction.
  TRotation GeneratorToDetector(TVector3 const& nuDir, double phi = 0.);

  /// Rotates a 4-vector's momentum (the target is at rest in both frames).
  TLorentzVector Rotate(TRotation const& r, TLorentzVector const& p4);

} // namespace ubext

#endif // UBSIM_EXTGEN_EXTGENIO_H
