import XCTest

final class OnboardingTests: XCTestCase {
    func testNativeOnboardingAndProfileKits() {
        let app = XCUIApplication()
        app.launchArguments = ["--sync-url", "http://localhost:4000"]
        app.launch()
        // Once reinstalls this disposable test app, removing its document but
        // retaining Keychain. Exercise the explicit incomplete-setup recovery.
        if app.buttons["Discard orphaned key"].waitForExistence(timeout: 3) {
            app.buttons["Discard orphaned key"].tap()
            app.buttons["Discard key & restart setup"].tap()
        }
        if app.buttons["habibi.create"].waitForExistence(timeout: 10) {
            app.buttons["habibi.create"].tap()
            let name = app.textFields["habibi.name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            name.tap()
            name.typeText("Noor")
            app.buttons["habibi.continue"].tap()
            let health = app.switches["habibi.interest.health"]
            health.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -30, dy: 0)).tap()
            XCTAssertEqual(health.value as? String, "1")
            app.buttons["habibi.continue"].tap()
            app.swipeUp()
            let understood = app.switches["habibi.understood"]
            understood.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -30, dy: 0)).tap()
            XCTAssertEqual(understood.value as? String, "1")
            XCTAssertTrue(app.buttons["habibi.continue"].isEnabled)
            app.buttons["habibi.continue"].tap()
        }
        let home = app.buttons.matching(NSPredicate(format: "identifier == 'house' OR label == 'Home'")).firstMatch
        let conversations = app.buttons.matching(NSPredicate(format: "identifier == 'bubble.left.and.bubble.right' OR label == 'Conversations'")).firstMatch
        let profile = app.buttons.matching(NSPredicate(format: "identifier == 'person.crop.circle' OR label == 'Profile'")).firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        XCTAssertTrue(conversations.exists)
        let heartling = app.buttons["habibi.heartling"]
        XCTAssertTrue(heartling.exists)
        heartling.tap()
        XCTAssertEqual(heartling.value as? String, "A curious hello")
        profile.tap()
        app.buttons["habibi.profile.appearance"].tap()
        app.buttons["habibi.theme.clay"].tap()
        let clay = app.buttons["habibi.theme.clay"]
        let selected = NSPredicate(format: "selected == true")
        expectation(for: selected, evaluatedWith: clay)
        waitForExpectations(timeout: 5)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for icon in ["midnight", "blossom", "forest"] {
            let choice = app.buttons["habibi.icon.\(icon)"]
            for _ in 0..<4 where !choice.isHittable { app.swipeDown() }
            app.swipeDown()
            XCTAssertTrue(choice.isEnabled)
            choice.tap()
            let notice = springboard.alerts.firstMatch
            if notice.waitForExistence(timeout: 3) { notice.buttons["OK"].tap() }
            if app.alerts.firstMatch.exists { app.alerts.buttons["OK"].tap() }
            expectation(for: selected, evaluatedWith: choice)
            waitForExpectations(timeout: 10)
            XCTAssertFalse(app.staticTexts["habibi.icon.error"].exists)
            let settings = XCTAttachment(screenshot: app.screenshot())
            settings.name = "AppIcon-\(icon)-Settings"; settings.lifetime = .keepAlways; add(settings)
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(springboard.icons["Habibi"].waitForExistence(timeout: 10))
            let launcher = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            launcher.name = "AppIcon-\(icon)-Home"; launcher.lifetime = .keepAlways; add(launcher)
            app.terminate(); app.launch()
            XCTAssertTrue(home.waitForExistence(timeout: 10))
            profile.tap(); app.buttons["habibi.profile.appearance"].tap()
            XCTAssertTrue(choice.isSelected, "The operating system must retain \(icon) after relaunch")
            XCTAssertTrue(app.buttons["habibi.theme.clay"].isSelected, "Icon choice must not change the synced theme")
        }
        app.navigationBars.buttons["Profile"].tap()
        app.buttons["habibi.profile.kits"].tap()
        XCTAssertTrue(app.navigationBars["Kits"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.tabBars.count, 0)
        XCTAssertTrue(app.buttons["habibi.kits.create"].exists)
        let bundledGitHub = app.buttons["habibi.kits.bundled.github"]
        XCTAssertTrue(bundledGitHub.waitForExistence(timeout: 5))
        app.buttons["habibi.kits.connected"].tap()
        XCTAssertTrue(app.staticTexts["No connected Kits"].waitForExistence(timeout: 5))
        XCTAssertFalse(bundledGitHub.exists)
        app.buttons["habibi.kits.filter.personal"].tap()
        XCTAssertFalse(bundledGitHub.exists)
        app.buttons["habibi.kits.filter.all"].tap()
        let search = app.textFields["habibi.kits.search"]
        search.tap()
        search.typeText("  PUBLIC  ")
        XCTAssertEqual(app.tabBars.count, 0)
        XCTAssertTrue(bundledGitHub.waitForExistence(timeout: 5))
        app.buttons["Clear search"].tap()
        XCTAssertEqual(search.value as? String, "Search Kits")
        search.typeText("not-a-real-kit")
        XCTAssertTrue(app.staticTexts["No Kits found"].waitForExistence(timeout: 5))
        XCTAssertFalse(bundledGitHub.exists)
        app.buttons["Clear search"].tap()
        XCTAssertEqual(search.value as? String, "Search Kits")
        search.typeText("GitHub\n")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(app.tabBars.count, 0)
        bundledGitHub.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "kit-presentation").firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["habibi.kit.page.fallback"].exists)
        XCTAssertTrue(app.staticTexts["habibi.github.disclosure"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["habibi.github.client-id"].exists)
        let connect = app.buttons["habibi.github.connect"]
        if !connect.exists { app.swipeUp() }
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        if app.staticTexts["habibi.github.unconfigured"].exists { XCTAssertFalse(connect.isEnabled) }
        else { XCTAssertTrue(connect.isEnabled) }
        app.buttons["habibi.github.close"].tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "GitHub")
        XCTAssertTrue(bundledGitHub.exists)
        XCTAssertEqual(app.tabBars.count, 0)
        app.navigationBars.buttons["Profile"].tap()
        XCTAssertTrue(app.buttons["habibi.profile.kits"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.tabBars.count, 1)
        XCTAssertFalse(search.exists)
        app.buttons["habibi.profile.kits"].tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertEqual(app.tabBars.count, 0)
        app.buttons["habibi.kits.create"].tap()
        let composer = app.descendants(matching: .any).matching(identifier: "habibi.composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Help me make my own Kit.")
        XCTAssertEqual(app.tabBars.count, 0)
        XCTAssertTrue(app.buttons["habibi.microphone"].exists)
        XCTAssertFalse(app.buttons["habibi.send"].isEnabled)
        app.navigationBars.buttons["Conversations"].tap()
        XCTAssertTrue(app.buttons["habibi.conversation.new"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.tabBars.count, 1)
        app.buttons["habibi.conversation.new"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertNotEqual(composer.value as? String, "Help me make my own Kit.")
        composer.tap()
        composer.typeText("Second independent draft")
        let keyboardDone = app.buttons["habibi.keyboard.done"]
        XCTAssertTrue(keyboardDone.waitForExistence(timeout: 5))
        keyboardDone.tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(composer.value as? String, "Second independent draft")
        app.navigationBars.buttons["Conversations"].tap()
        app.buttons.containing(.staticText, identifier: "Help me make my own Kit.").firstMatch.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Help me make my own Kit.")
        XCTAssertEqual(app.tabBars.count, 0)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "habibi.conversations.saved").firstMatch.waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["habibi.create"].exists)
        conversations.tap()
        app.buttons.containing(.staticText, identifier: "Help me make my own Kit.").firstMatch.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Help me make my own Kit.")
        XCTAssertEqual(app.tabBars.count, 0)
        app.navigationBars.buttons["Conversations"].tap()
        app.buttons.containing(.staticText, identifier: "Second independent draft").firstMatch.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Second independent draft")
        app.navigationBars.buttons["Conversations"].tap()
        profile.tap()
        app.buttons["habibi.profile.appearance"].tap()
        XCTAssertTrue(app.buttons["habibi.theme.clay"].isSelected)
    }
}
