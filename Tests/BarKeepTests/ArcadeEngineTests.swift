import XCTest
@testable import BarKeep

final class ArcadeEngineTests: XCTestCase {
    func testEveryGameRendersAVisibleNativeResolutionFrame() {
        for game in ArcadeGame.allCases {
            let engine = ArcadeEngine(game: game)
            XCTAssertEqual(engine.frame.pixels.count, 72 * 16, game.title)
            XCTAssertTrue(
                engine.frame.pixels.contains(where: { $0 != .black }),
                "\(game.title) should render visible pixels"
            )
        }
    }

    func testSnakeMovesOnItsTick() {
        var engine = ArcadeEngine(game: .snake)
        let initial = engine.frame
        engine.update(now: 1, held: [], pressed: [.down])
        XCTAssertNotEqual(engine.frame, initial)
    }

    func testTetrisHardDropChangesTheBoard() {
        var engine = ArcadeEngine(game: .tetris)
        let initial = engine.frame
        engine.update(now: 1, held: [], pressed: [.space])
        XCTAssertNotEqual(engine.frame, initial)
    }

    func testPongAndBreakoutAnimate() {
        for game in [ArcadeGame.pong, .breakout] {
            var engine = ArcadeEngine(game: game)
            let initial = engine.frame
            for tick in 1...5 {
                engine.update(
                    now: Double(tick) / 60,
                    held: game == .breakout ? [.left] : [],
                    pressed: []
                )
            }
            XCTAssertNotEqual(engine.frame, initial, game.title)
        }
    }

    func testBallGamesRemainRenderableDuringLongSessions() {
        for game in [ArcadeGame.pong, .breakout] {
            var engine = ArcadeEngine(game: game)
            for tick in 1...20_000 {
                engine.update(
                    now: Double(tick) / 60,
                    held: tick.isMultiple(of: 120) ? [.left] : [],
                    pressed: []
                )
            }

            XCTAssertEqual(engine.frame.pixels.count, 72 * 16)
            XCTAssertTrue(
                engine.frame.pixels.contains { $0 != .black },
                "\(game.title) produced a blank frame after a long session"
            )
        }
    }

    @MainActor
    func testArcadeFrameEncodesAsPNG() {
        let engine = ArcadeEngine(game: .snake)
        let data = ArcadeRenderer.pngData(from: engine.frame)
        XCTAssertNotNil(data)
        XCTAssertEqual(
            Array(data?.prefix(8) ?? Data()),
            [137, 80, 78, 71, 13, 10, 26, 10]
        )
    }
}
