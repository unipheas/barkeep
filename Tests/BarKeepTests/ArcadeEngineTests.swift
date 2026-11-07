import XCTest
@testable import BarKeep

final class ArcadeEngineTests: XCTestCase {
    func testStoppingInvalidatesFrameWithoutAbandoningUpload() {
        var lifecycle = ArcadeUploadLifecycle()
        lifecycle.beginSession()
        let uploadSession = lifecycle.beginUpload()

        lifecycle.invalidateSession()

        XCTAssertEqual(lifecycle.uploadSession, uploadSession)
        XCTAssertFalse(
            lifecycle.shouldDraw(uploadSession: uploadSession, isActive: false)
        )
        XCTAssertTrue(lifecycle.finishUpload(uploadSession))
        XCTAssertNil(lifecycle.uploadSession)
    }

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

    func testSnakeGrowsOnFoodAndRestartsAfterWallCollision() {
        var engine = ArcadeEngine(game:.snake)
        let initial = engine.frame
        for tick in 1...16 { engine.update(now:Double(tick),held:[],pressed:[]) }
        XCTAssertEqual(engine.frame.pixels.filter { $0 == .green || $0 == .yellow }.count,12)
        for tick in 17...26 { engine.update(now:Double(tick),held:[],pressed:[]) }
        XCTAssertEqual(engine.frame,initial,"Wall collision should reset the round")
        for (tick,key) in [ArcadeKey.up,.left,.down,.right].enumerated() {
            let before=engine.frame
            engine.update(now:Double(tick+30),held:[],pressed:[key])
            XCTAssertNotEqual(engine.frame,before)
        }
        engine.update(now:40,held:[],pressed:[.restart])
        XCTAssertEqual(engine.frame,initial)
    }

    func testTetrisMovementRotationGravityAndRepeatedDrops() {
        var engine = ArcadeEngine(game:.tetris)
        let initial=engine.frame
        engine.update(now:0,held:[],pressed:[.left])
        XCTAssertNotEqual(engine.frame,initial)
        engine.update(now:0,held:[],pressed:[.right])
        XCTAssertEqual(engine.frame,initial)
        for tick in 1...200 {
            let keys: [ArcadeKey] = [.up,.left,.right,.space]
            engine.update(now:Double(tick),held:[.down],pressed:[keys[tick % keys.count]])
            XCTAssertEqual(engine.frame.pixels.count,72*16)
            XCTAssertTrue(engine.frame.pixels.contains { $0 != .black })
        }
    }

    func testPaddleInputMovesAndClampsAtScreenEdges() {
        for game in [ArcadeGame.pong,.breakout] {
            var engine=ArcadeEngine(game:game)
            let initial=engine.frame
            for tick in 1...100 { engine.update(now:Double(tick),held:game == .pong ? [.up] : [.left],pressed:[]) }
            XCTAssertNotEqual(engine.frame,initial)
            for tick in 101...200 { engine.update(now:Double(tick),held:game == .pong ? [.s] : [.right],pressed:[]) }
            let color: ArcadeColor = game == .pong ? .cyan : .white
            XCTAssertTrue(engine.frame.pixels.contains { $0 == color })
            engine.update(now:201,held:[],pressed:[.restart])
            XCTAssertEqual(engine.frame,initial)
        }
        var frame=ArcadeFrame()
        frame.rectangle(x:-2,y:-2,width:4,height:4,color:.red)
        XCTAssertEqual(frame.pixels.filter { $0 == .red }.count,4,"Offscreen pixels must be clipped")
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
