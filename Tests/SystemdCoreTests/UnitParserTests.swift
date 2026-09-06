import XCTest
@testable import SystemdCore

final class UnitParserTests: XCTestCase {
    func testParsesSystemdStyleService() throws {
        let text = """
        [Unit]
        Description=Example service
        Wants=network-online.target
        After=network-online.target
        
        [Service]
        Type=simple
        ExecStart=/usr/bin/example --listen 127.0.0.1:8080
        Restart=on-failure
        RestartSec=250ms
        User=nobody
        Group=staff
        SupplementaryGroups=wheel network
        UMask=027
        LimitNOFILE=1048576
        CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
        AmbientCapabilities=CAP_NET_ADMIN
        NoNewPrivileges=no
        Environment=FOO=bar
        RemainAfterExit=no
        
        [Install]
        WantedBy=multi-user.target
        """

        let unit = try UnitParser().parse(text: text, name: "example.service")
        XCTAssertEqual(unit.name, "example.service")
        XCTAssertEqual(unit.description, "Example service")
        XCTAssertEqual(unit.wants, ["network-online.target"])
        XCTAssertEqual(unit.after, ["network-online.target"])
        XCTAssertEqual(unit.service.type, .simple)
        XCTAssertEqual(unit.service.execStart, ["/usr/bin/example --listen 127.0.0.1:8080"])
        XCTAssertEqual(unit.service.restart, .onFailure)
        XCTAssertEqual(unit.service.restartSec, 0.25, accuracy: 0.0001)
        XCTAssertEqual(unit.service.user, "nobody")
        XCTAssertEqual(unit.service.group, "staff")
        XCTAssertEqual(unit.service.supplementaryGroups, ["wheel", "network"])
        XCTAssertEqual(unit.service.umask, 0o27)
        XCTAssertEqual(unit.service.limitNOFILE, 1_048_576)
        XCTAssertEqual(unit.service.capabilityBoundingSet, ["CAP_NET_ADMIN", "CAP_NET_RAW"])
        XCTAssertEqual(unit.service.ambientCapabilities, ["CAP_NET_ADMIN"])
        XCTAssertFalse(unit.service.noNewPrivileges)
        XCTAssertEqual(unit.service.environment["FOO"], "bar")
        XCTAssertEqual(unit.wantedBy, ["multi-user.target"])
    }

    func testDurationParsing() throws {
        let parser = UnitParser()
        XCTAssertEqual(try parser.parseDuration("500ms"), 0.5, accuracy: 0.0001)
        XCTAssertEqual(try parser.parseDuration("2min"), 120, accuracy: 0.0001)
        XCTAssertEqual(try parser.parseDuration("1h"), 3600, accuracy: 0.0001)
    }

    func testRejectsInvalidLimitNOFILE() {
        let text = """
        [Service]
        Type=simple
        ExecStart=/usr/bin/example
        LimitNOFILE=not-a-number
        """
        XCTAssertThrowsError(try UnitParser().parse(text: text, name: "example.service"))
    }

    func testRejectsInvalidUMask() {
        let text = """
        [Service]
        Type=simple
        ExecStart=/usr/bin/example
        UMask=999
        """
        XCTAssertThrowsError(try UnitParser().parse(text: text, name: "example.service"))
    }

    func testRejectsNonServiceUnit() {
        XCTAssertThrowsError(try UnitParser().parse(text: "[Unit]", name: "example.socket"))
    }
}
