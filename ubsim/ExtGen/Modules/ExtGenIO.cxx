////////////////////////////////////////////////////////////////////////
/// \file  ExtGenIO.cxx
/// \brief See ExtGenIO.h
////////////////////////////////////////////////////////////////////////

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>

#include "cetlib_except/exception.h"

#include "ubsim/ExtGen/Modules/ExtGenIO.h"

namespace {

  // Exact conversion of a %.17g string to double (strtod rounds correctly);
  // the whole token must be a number.
  double ToDouble(std::string const& s, std::string const& where)
  {
    char* end = nullptr;
    const double v = std::strtod(s.c_str(), &end);
    if (s.empty() || *end != '\0') {
      throw cet::exception("ExtGenIO") << "bad number '" << s << "' in " << where << "\n";
    }
    return v;
  }

  std::string Where(std::string const& path, unsigned long lineno)
  {
    return path + ":" + std::to_string(lineno);
  }

} // namespace

namespace ubext {

  //----------------------------------------------------------------------------
  RequestFile ReadRequests(std::string const& path)
  {
    std::ifstream in(path);
    if (!in.is_open()) {
      throw cet::exception("ExtGenIO") << "cannot open request file '" << path << "'\n";
    }
    RequestFile rf;
    std::string line;
    unsigned long lineno = 0;
    while (std::getline(in, line)) {
      ++lineno;
      if (line.empty()) continue;
      if (line[0] == '#') { rf.header.push_back(line); continue; }

      std::istringstream ss(line);
      std::vector<std::string> cols;
      std::string c;
      while (ss >> c) cols.push_back(c);
      if (cols.size() != 16) {
        throw cet::exception("ExtGenIO") << Where(path, lineno) << ": " << cols.size()
                                         << " columns in request line, expected 16\n";
      }
      Request r;
      r.reqId = std::stol(cols[0]);
      r.run = std::stoul(cols[1]);
      r.subRun = std::stoul(cols[2]);
      r.event = std::stoul(cols[3]);
      r.truthIdx = std::stoul(cols[4]);
      r.nuPdg = std::stoi(cols[5]);
      if (cols[6] != "CC" && cols[6] != "NC") {
        throw cet::exception("ExtGenIO") << Where(path, lineno) << ": bad current '"
                                         << cols[6] << "'\n";
      }
      r.isCC = (cols[6] == "CC");
      r.tgtPdg = std::stoi(cols[7]);
      r.E = ToDouble(cols[8], Where(path, lineno));

      const RequestKey key(r.run, r.subRun, r.event, r.truthIdx);
      if (!rf.requests.emplace(key, r).second) {
        throw cet::exception("ExtGenIO") << Where(path, lineno)
                                         << ": duplicate request for run " << r.run
                                         << " subrun " << r.subRun << " event " << r.event
                                         << " truth " << r.truthIdx << "\n";
      }
    }
    return rf;
  }

  //----------------------------------------------------------------------------
  ServedFile ReadServed(std::string const& path)
  {
    std::ifstream in(path);
    if (!in.is_open()) {
      throw cet::exception("ExtGenIO") << "cannot open served-event file '" << path << "'\n";
    }
    ServedFile sf;
    std::string line;
    unsigned long lineno = 0;
    ServedEvent* current = nullptr;
    unsigned long expected = 0;

    while (std::getline(in, line)) {
      ++lineno;
      if (line.empty()) continue;
      if (line[0] == '#') { sf.header.push_back(line); continue; }

      std::istringstream ss(line);
      std::vector<std::string> cols;
      std::string c;
      while (ss >> c) cols.push_back(c);
      if (cols.empty()) continue;

      if (cols[0] == "EVENT") {
        if (current && current->particles.size() != expected) {
          throw cet::exception("ExtGenIO") << Where(path, lineno) << ": request "
                                           << current->reqId << " has "
                                           << current->particles.size()
                                           << " particles, header says " << expected << "\n";
        }
        if (cols.size() != 7) {
          throw cet::exception("ExtGenIO") << Where(path, lineno)
                                           << ": EVENT line needs 6 fields\n";
        }
        ServedEvent ev;
        ev.reqId = std::stol(cols[1]);
        ev.E = ToDouble(cols[2], Where(path, lineno));
        ev.genProc = std::stol(cols[3]);
        ev.mode = std::stoi(cols[4]);
        ev.intType = std::stoi(cols[5]);
        expected = std::stoul(cols[6]);
        auto ins = sf.events.emplace(ev.reqId, ev);
        if (!ins.second) {
          throw cet::exception("ExtGenIO") << Where(path, lineno) << ": request "
                                           << ev.reqId << " served twice\n";
        }
        current = &ins.first->second;
      }
      else if (cols[0] == "P") {
        if (!current) {
          throw cet::exception("ExtGenIO") << Where(path, lineno) << ": P line before EVENT\n";
        }
        if (cols.size() != 7) {
          throw cet::exception("ExtGenIO") << Where(path, lineno)
                                           << ": P line needs 6 fields\n";
        }
        ServedParticle p;
        p.status = std::stoi(cols[1]);
        p.pdg = std::stoi(cols[2]);
        p.p4.SetPxPyPzE(ToDouble(cols[3], Where(path, lineno)),
                        ToDouble(cols[4], Where(path, lineno)),
                        ToDouble(cols[5], Where(path, lineno)),
                        ToDouble(cols[6], Where(path, lineno)));
        current->particles.push_back(p);
      }
      else {
        throw cet::exception("ExtGenIO") << Where(path, lineno) << ": unknown line type '"
                                         << cols[0] << "'\n";
      }
    }
    if (current && current->particles.size() != expected) {
      throw cet::exception("ExtGenIO") << path << ": request " << current->reqId << " has "
                                       << current->particles.size()
                                       << " particles, header says " << expected << "\n";
    }
    return sf;
  }

  //----------------------------------------------------------------------------
  void WriteServedEvent(FILE* out, ServedEvent const& ev)
  {
    std::fprintf(out, "EVENT %ld %.17g %ld %d %d %zu\n", ev.reqId, ev.E, ev.genProc,
                 ev.mode, ev.intType, ev.particles.size());
    for (auto const& p : ev.particles) {
      std::fprintf(out, "P %d %d %.17g %.17g %.17g %.17g\n", p.status, p.pdg,
                   p.p4.Px(), p.p4.Py(), p.p4.Pz(), p.p4.E());
    }
  }

  //----------------------------------------------------------------------------
  TRotation GeneratorToDetector(TVector3 const& nuDir, double phi)
  {
    // The rotation TVector3::RotateUz(u) applies (+z onto u), as a matrix:
    // its columns are the images of the x, y and z axes.
    const TVector3 u = nuDir.Unit();
    const double up = std::sqrt(u.X() * u.X() + u.Y() * u.Y());
    TRotation toU;
    if (up > 0.) {
      toU.RotateAxes(TVector3(u.X() * u.Z() / up, u.Y() * u.Z() / up, -up),
                     TVector3(-u.Y() / up, u.X() / up, 0.), u);
    }
    else if (u.Z() < 0.) {
      toU.RotateAxes(TVector3(-1., 0., 0.), TVector3(0., 1., 0.), TVector3(0., 0., -1.));
    }

    TRotation r;
    r.RotateZ(phi);    // azimuth about the beam axis (generator frame)
    r.Transform(toU);  // then +z onto the neutrino direction (r = toU * Rz)
    return r;
  }

  //----------------------------------------------------------------------------
  TLorentzVector Rotate(TRotation const& r, TLorentzVector const& p4)
  {
    return TLorentzVector(r * p4.Vect(), p4.E());
  }

} // namespace ubext
