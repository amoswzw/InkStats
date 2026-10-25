import Foundation
import HelperShared
import os

let log = Logger(subsystem: HelperIdentity.helperIdentifier, category: "helper")

// Clients must carry the same team ID as this helper, so a build signed with any
// other certificate, or none, can't drive a root process.
guard let team = HelperIdentity.signingTeam() else {
    // Fail closed: an unsigned or ad-hoc signed helper accepts no connections at all.
    log.error("Helper has no team identifier; refusing to start")
    exit(1)
}

// A crash or forced stop could have left fans pinned; start from automatic.
FanControl.shared.resetAll()

let service = HelperService()
let listener = NSXPCListener(machServiceName: HelperIdentity.machService)
listener.setConnectionCodeSigningRequirement(HelperIdentity.requirement(identifier: HelperIdentity.appIdentifier, team: team))
listener.delegate = service
listener.resume()

for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        FanControl.shared.resetAll()
        exit(0)
    }
    source.resume()
    service.retain(source)
}

log.info("Helper \(HelperIdentity.version, privacy: .public) listening for team \(team, privacy: .public)")
dispatchMain()
