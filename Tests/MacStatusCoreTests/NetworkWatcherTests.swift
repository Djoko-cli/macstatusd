import XCTest
import Network
@testable import MacStatusNet

/// Lot 2, point 8 : la signature du chemin réseau ne compte que le Wi-Fi, l'Ethernet filaire et le
/// cellulaire. Un tunnel (VPN), le bouclage ou une interface « autre » qui apparaît ou disparaît ne
/// relance donc aucun envoi.
final class NetworkWatcherTests: XCTestCase {
    private typealias Interface = (name: String, type: NWInterface.InterfaceType)

    private func signature(_ interfaces: [Interface], statut status: NWPath.Status = .satisfied) -> String {
        NetworkPathSignature.make(status: status, interfaces: interfaces)
    }

    func test_interfacesNonPertinentes_neChangentPasLaSignature() {
        let base = signature([("en0", .wifi)])
        XCTAssertEqual(signature([("en0", .wifi), ("utun4", .other)]), base, "un tunnel n'est pas un changement")
        XCTAssertEqual(signature([("en0", .wifi), ("lo0", .loopback)]), base)
        XCTAssertEqual(signature([("en0", .wifi), ("utun4", .other), ("utun5", .other), ("lo0", .loopback)]), base)
    }

    func test_interfacesPertinentes_changentLaSignature() {
        let wifi = signature([("en0", .wifi)])
        XCTAssertNotEqual(signature([("en1", .wiredEthernet)]), wifi, "du Wi-Fi à l'Ethernet")
        XCTAssertNotEqual(signature([("en0", .wifi), ("en1", .wiredEthernet)]), wifi)
        XCTAssertNotEqual(signature([("en0", .wifi), ("pdp_ip0", .cellular)]), wifi)
        XCTAssertNotEqual(signature([("en0", .wifi)]), signature([("en2", .wifi)]), "autre interface Wi-Fi")
    }

    func test_ordreDesInterfaces_neComptePas() {
        XCTAssertEqual(signature([("en0", .wifi), ("en1", .wiredEthernet)]),
                       signature([("en1", .wiredEthernet), ("en0", .wifi)]))
    }

    func test_statutChange_changeLaSignature() {
        XCTAssertNotEqual(signature([("en0", .wifi)], statut: .satisfied), signature([("en0", .wifi)], statut: .unsatisfied))
    }
}
