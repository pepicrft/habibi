import XCTest

final class OnboardingTests: XCTestCase {
    func testConversationIdeasPullPageDismissAndPreserveEditableDraft() {
        let app = launchHabibi()
        app.buttons.matching(NSPredicate(format: "identifier == 'bubble.left.and.bubble.right' OR label == 'Conversations'")).firstMatch.tap()
        app.buttons["habibi.conversation.new"].tap()
        let composer = app.descendants(matching: .any).matching(identifier: "habibi.composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap(); composer.typeText("Keep my own words.")
        app.buttons["habibi.keyboard.done"].tap()
        let carousel = app.scrollViews["habibi.ideas.carousel"]
        let cue = app.staticTexts["habibi.ideas.pull"]
        XCTAssertFalse(app.buttons["habibi.ideas.toggle"].exists, "Ideas must not have an always-visible control")
        XCTAssertFalse(cue.exists, "The cue stays hidden before pulling past the bottom")
        capture(app, "Ideas-Collapsed")

        // The scroll view's accessibility frame includes the dock, so start just above it.
        let bottom = app.buttons["habibi.costume.conversation"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: -60))
        func revealIdeas() {
            for _ in 0..<5 where !carousel.exists {
                bottom.press(forDuration: 0.1, thenDragTo: bottom.withOffset(CGVector(dx: 0, dy: -250)),
                             withVelocity: .slow, thenHoldForDuration: 0.5)
            }
            XCTAssertTrue(carousel.waitForExistence(timeout: 5), "Pulling past the conversation's end opens ideas")
        }
        revealIdeas()
        XCTAssertTrue(app.buttons["habibi.idea.0"].isHittable)
        XCTAssertTrue(composer.isHittable, "The composer stays available beneath the ideas")
        capture(app, "Ideas-Expanded")
        carousel.swipeLeft()
        let secondPage = app.buttons["Idea 2 of 4"]
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: secondPage)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["habibi.idea.1"].isHittable)
        capture(app, "Ideas-Second-Page")
        carousel.swipeDown()
        XCTAssertFalse(carousel.exists)
        XCTAssertEqual(composer.value as? String, "Keep my own words.")

        bottom.press(forDuration: 0.1, thenDragTo: bottom.withOffset(CGVector(dx: 0, dy: -36)))
        XCTAssertFalse(carousel.exists, "A short pull at the bottom must not open ideas")
        XCTAssertFalse(cue.exists, "The cue disappears after releasing a short pull")
        capture(app, "Ideas-At-Bottom")
        revealIdeas()
        app.buttons["Idea 3 of 4"].tap()
        app.buttons["habibi.idea.2"].tap()
        XCTAssertFalse(carousel.exists)
        let expected = "Keep my own words.\n\nHelp me learn something new. Ask what I’m curious about, then guide me one step at a time."
        XCTAssertEqual(composer.value as? String, expected)
        XCTAssertTrue(app.staticTexts["What’s on your mind?"].exists, "Choosing an idea must not send a message")
        // Saving reconciles draft versions and can change the dock's height.
        XCTAssertTrue(app.staticTexts["habibi.conversations.saved"].waitForExistence(timeout: 5))
        capture(app, "Ideas-Editable-Draft")
        revealIdeas()
        app.buttons["habibi.ideas.close"].tap()
        XCTAssertFalse(carousel.exists)
        XCTAssertEqual(composer.value as? String, expected)
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["habibi.keyboard.done"].tap()
        XCTAssertEqual(composer.value as? String, expected)
        XCTAssertFalse(cue.exists)
    }

    func testProviderAndPrivacyUseFocusedNavigationAndExplicitDisclosure() {
        let app = launchHabibi()
        app.buttons.matching(NSPredicate(format: "identifier == 'person.crop.circle' OR label == 'Profile'")).firstMatch.tap()
        app.buttons["habibi.profile.provider"].tap()
        XCTAssertTrue(app.navigationBars["AI provider"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.tabBars.count, 0)
        XCTAssertTrue(app.staticTexts["habibi.model.availability"].exists)
        if app.buttons["habibi.model.check"].exists {
            app.buttons["habibi.model.check"].tap()
            XCTAssertTrue(app.staticTexts["habibi.model.availability"].exists)
        }
        XCTAssertTrue(app.buttons["habibi.chatgpt.connect"].exists)
        capture(app, "Provider-Overview")
        app.buttons["Connection privacy"].tap()
        let disclosure = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'After your approval, messages, requested Kit code'" )).firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        XCTAssertTrue(disclosure.label.contains("Anything you type in chat is still shared"))
        capture(app, "Provider-Privacy-Expanded")
        app.navigationBars.buttons["Profile"].tap()
        XCTAssertEqual(app.tabBars.count, 1)
        let privacy = app.buttons["habibi.profile.privacy"]
        for _ in 0..<4 where !privacy.isHittable { app.swipeUp() }
        privacy.tap()
        XCTAssertTrue(app.navigationBars["Privacy & storage"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.tabBars.count, 0)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Habibi creates your encryption key'" )).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Rust'" )).firstMatch.exists)
        capture(app, "Privacy-Storage")
        let encryption = app.buttons["Encryption details"]
        for _ in 0..<6 where !encryption.isHittable { app.swipeUp() }
        encryption.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Your vault uses a random 256-bit key'" )).firstMatch.waitForExistence(timeout: 5))
        capture(app, "Privacy-Encryption-Expanded")
        app.navigationBars.buttons["Profile"].tap()
        XCTAssertEqual(app.tabBars.count, 1)
    }

    func testPlusExplainsTheBoundaryWithoutBlockingLocalUse() {
        let app = launchHabibi()
        app.buttons.matching(NSPredicate(format: "identifier == 'person.crop.circle' OR label == 'Profile'")).firstMatch.tap()
        app.buttons["habibi.profile.plus"].tap()
        XCTAssertTrue(app.navigationBars["Habibi Plus"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Encrypted sync across your devices"].exists)
        XCTAssertTrue(app.staticTexts["Conversations, on-device AI, local Kits, skins, encryption and recovery backups. No subscription needed."].exists)
        XCTAssertEqual(app.tabBars.count, 0)
        capture(app, "Plus-Free-Overview")
        app.swipeUp()
        let signIn = app.buttons["habibi.plus.sign-in"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["habibi.plus.subscribe"].exists)
        XCTAssertFalse(app.buttons["habibi.plus.restore"].isEnabled)
        capture(app, "Plus-Unavailable-Plans")
        app.navigationBars.buttons["Profile"].tap()
        app.buttons["habibi.profile.kits"].tap()
        XCTAssertTrue(app.navigationBars["Kits"].waitForExistence(timeout: 5))
    }

    func testNativeOnboardingAndProfileKits() {
        let app = launchHabibi()
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
        app.navigationBars.buttons["Profile"].tap()
    }

    func testCostumesReviewTryOnAndConversationPersistence() {
        let app = launchHabibi()
        let home = app.buttons.matching(NSPredicate(format: "identifier == 'house' OR label == 'Home'")).firstMatch
        let conversations = app.buttons.matching(NSPredicate(format: "identifier == 'bubble.left.and.bubble.right' OR label == 'Conversations'")).firstMatch
        let profile = app.buttons.matching(NSPredicate(format: "identifier == 'person.crop.circle' OR label == 'Profile'")).firstMatch
        let composer = app.descendants(matching: .any).matching(identifier: "habibi.composer").firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        profile.tap()
        app.buttons["habibi.profile.costumes"].tap()
        XCTAssertTrue(app.navigationBars["Skins"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your wardrobe is ready for its first skin."].exists)
        XCTAssertEqual(app.tabBars.count, 0)
        capture(app, "Costumes-Empty-Wardrobe")
        app.buttons["habibi.costumes.bundled.Socratic Tutor"].tap()
        XCTAssertTrue(app.buttons["habibi.costumes.try"].waitForExistence(timeout: 5))
        capture(app, "Costumes-Tutor-Details")
        app.buttons["habibi.costumes.try"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Learn through questions and hints, one idea at a time."].exists)
        XCTAssertEqual(composer.value as? String, "Help me understand probability. Ask me a question to see where to begin.")
        XCTAssertEqual(app.buttons["habibi.costume.conversation"].label, "Wearing Socratic Tutor")
        XCTAssertFalse(app.buttons["habibi.send"].isEnabled)
        capture(app, "Costumes-Tutor-Conversation")
        app.navigationBars.buttons["Conversations"].tap()
        profile.tap()
        app.navigationBars.buttons["Skins"].tap()
        XCTAssertTrue(app.staticTexts["Your wardrobe is ready for its first skin."].exists)
        app.buttons["habibi.costumes.bundled.Socratic Tutor"].tap()
        let addCostume = app.buttons["habibi.costumes.add"]
        for _ in 0..<3 where !addCostume.isHittable { app.swipeUp() }
        addCostume.tap()
        XCTAssertTrue(app.textFields["habibi.costumes.name"].waitForExistence(timeout: 5))
        capture(app, "Costumes-Review")
        app.buttons["habibi.costumes.save"].tap()
        XCTAssertTrue(app.navigationBars["Socratic Tutor"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Skins"].tap()
        let savedCostume = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'habibi.costumes.saved.'")).firstMatch
        XCTAssertTrue(savedCostume.waitForExistence(timeout: 5))
        app.swipeDown()
        capture(app, "Costumes-Wardrobe")
        savedCostume.tap()
        let wearCostume = app.buttons["habibi.costumes.wear"]
        for _ in 0..<3 where !wearCostume.isHittable { app.swipeUp() }
        wearCostume.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap(); composer.typeText("A costume draft to keep")
        app.buttons["habibi.keyboard.done"].tap()
        XCTAssertEqual(app.buttons["habibi.costume.conversation"].label, "Wearing Socratic Tutor")
        app.navigationBars.buttons["Conversations"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        conversations.tap()
        app.buttons.containing(.staticText, identifier: "A costume draft to keep").firstMatch.tap()
        XCTAssertEqual(app.buttons["habibi.costume.conversation"].label, "Wearing Socratic Tutor")
        app.buttons["habibi.costume.conversation"].tap()
        XCTAssertTrue(app.buttons["habibi.costumes.take-off"].waitForExistence(timeout: 5))
        capture(app, "Costumes-Chooser")
        app.buttons["habibi.costumes.take-off"].tap()
        XCTAssertEqual(app.buttons["habibi.costume.conversation"].label, "Wear a skin")
        XCTAssertEqual(composer.value as? String, "A costume draft to keep")
    }

    private func launchHabibi() -> XCUIApplication {
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
            XCTAssertFalse(app.staticTexts["The private key or encrypted vault is missing. Your remaining data is untouched. Restore your backup to recover."].exists)
            name.tap()
            name.typeText("Noor")
            app.buttons["habibi.continue"].tap()
            let health = app.switches["habibi.interest.health"]
            health.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -30, dy: 0)).tap()
            XCTAssertEqual(health.value as? String, "1")
            app.buttons["habibi.continue"].tap()
            XCTAssertTrue(app.buttons["habibi.chatgpt.connect"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons["habibi.continue"].label, "Skip for now")
            let provider = XCTAttachment(screenshot: app.screenshot())
            provider.name = "ChatGPT-Onboarding"; provider.lifetime = .keepAlways; add(provider)
            app.buttons["habibi.continue"].tap()
            app.swipeUp()
            let understood = app.switches["habibi.understood"]
            understood.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -30, dy: 0)).tap()
            XCTAssertEqual(understood.value as? String, "1")
            XCTAssertTrue(app.buttons["habibi.continue"].isEnabled)
            app.buttons["habibi.continue"].tap()
        }
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
