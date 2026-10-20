import Testing
@testable import LogiHIDPP

@Suite struct HapticsTests {
    @Test func featureID() {
        #expect(Haptics.featureID == 0x19B0)
    }

    @Test func patternNumbers() {
        #expect(HapticPattern(0) == .sharpStateChange)
        #expect(HapticPattern(14) == .ringing)
        #expect(HapticPattern(0x1B) == .whisperCollision)
        #expect(HapticPattern(15) == nil)
        #expect(HapticPattern(0x1A) == nil)
        #expect(HapticPattern(255) == nil)
    }

    @Test func allSixteenPatternsInNumberOrder() {
        let numbers = HapticPattern.all.map(\.rawValue)
        #expect(numbers == Array(0x00...0x0E) + [0x1B])
        #expect(Set(HapticPattern.all.map(\.name)).count == 16)
    }

    @Test func patternByName() {
        #expect(HapticPattern(named: "subtle collision") == .subtleCollision)
        #expect(HapticPattern(named: "Whisper-Collision") == .whisperCollision)
        #expect(HapticPattern(named: "HAPPY_ALERT") == .happyAlert)
        #expect(HapticPattern(named: "bzzz") == nil)
    }

    @Test func choiceParsesNamesNumbersAndNone() {
        #expect(HapticChoice.parse("sharp-collision") == .some(HapticChoice(pattern: .sharpCollision)))
        #expect(HapticChoice.parse("Sharp_Collision strong") == .some(HapticChoice(pattern: .sharpCollision, strong: true)))
        #expect(HapticChoice.parse("  Sharp_Collision   STRONG ") == .some(HapticChoice(pattern: .sharpCollision, strong: true)))
        #expect(HapticChoice.parse("sharp state change strong") == .some(HapticChoice(pattern: .sharpStateChange, strong: true)))
        #expect(HapticChoice.parse("0x1b") == .some(HapticChoice(pattern: .whisperCollision)))
        #expect(HapticChoice.parse("0X0C") == .some(HapticChoice(pattern: .knock)))
        #expect(HapticChoice.parse("27") == .some(HapticChoice(pattern: .whisperCollision)))
        #expect(HapticChoice.parse("0x1b strong") == .some(HapticChoice(pattern: .whisperCollision, strong: true)))
        #expect(HapticChoice.parse("4\tstrong") == .some(HapticChoice(pattern: .subtleCollision, strong: true)))
        #expect(HapticChoice.parse("none") == .some(nil))
        #expect(HapticChoice.parse("NONE") == .some(nil))
    }

    @Test func choiceRejectsWhatIsNotAPattern() {
        for bad in ["strong", "none strong", "", "0x0f", "0xff", "15", "15 strong", "+4", "-1", "0x", "0x+1", "bzzz",
                    "bzzz strong", "sharp-collision loud", "sharp-collisionstrong"] {
            #expect(HapticChoice.parse(bad) == nil, "\(bad)")
        }
    }

    @Test func choiceTextAndRoundTrip() {
        #expect(HapticChoice.text(HapticChoice(pattern: .sharpCollision, strong: true)) == "sharp-collision strong")
        #expect(HapticChoice.text(HapticChoice(pattern: .whisperCollision)) == "whisper-collision")
        #expect(HapticChoice.text(nil) == "none")
        #expect(HapticPattern.whisperCollision.configName == "whisper-collision")
        #expect(HapticChoice.parse(HapticChoice.text(nil)) == .some(nil))
        for pattern in HapticPattern.all {
            for strong in [false, true] {
                let choice = HapticChoice(pattern: pattern, strong: strong)
                #expect(HapticChoice.parse(HapticChoice.text(choice)) == .some(choice))
            }
        }
    }

    @Test func configFromRecordedReply() throws {
        let report = try #require(HIDPPReport(bytes: Fixtures.hapticConfig))
        let config = Haptics.config(from: report.params)
        #expect(config == (true, 25))
        #expect(Haptics.config(from: [0x01, 0x19]) == (true, 25))
        #expect(Haptics.config(from: [0x00, 0x19]) == (false, 25))
    }

    @Test func configShortParamsIsDisabled() {
        #expect(Haptics.config(from: []) == (false, 0))
        #expect(Haptics.config(from: [0x01]) == (false, 0))
    }

    @Test func playParamsIsThePatternByte() throws {
        #expect(Haptics.playParams(try #require(HapticPattern(3))) == [0x03])
        #expect(Haptics.playParams(try #require(HapticPattern(14))) == [0x0E])
        #expect(Haptics.playParams(.whisperCollision) == [0x1B])
    }

    @Test func setConfigParamsEnableWithTheStrength() throws {
        #expect(Haptics.setConfigParams(strength: 80) == [0x01, 0x50])
        let echo = try #require(HIDPPReport(bytes: Fixtures.hapticStrengthEcho)).params
        #expect(Haptics.setConfigParams(strength: 35) == Array(echo.prefix(2)))
    }

    @Test func latestOnlyKeepsTheNewest() {
        var slot = LatestOnly<Int>()
        #expect(slot.take() == nil)
        slot.put(1)
        slot.put(2)
        #expect(slot.take() == 2)
        #expect(slot.take() == nil)
        slot.put(3)
        #expect(slot.take() == 3)
    }
}
