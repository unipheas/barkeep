import XCTest
@testable import BarKeep

final class ArcadeScoringTests: XCTestCase {
    func testPongPaddleCollisionsReverseAndBoundVelocity() {
        var player = PongState(ballX: 2.5, ballY: 8, velocityX: -0.5, velocityY: 0.2)
        player.update(held: [])
        XCTAssertEqual(player.velocityX, 0.525, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(abs(player.velocityY), 0.9)
        XCTAssertEqual(player.computerScore, 0)
        var computer = PongState(ballX: 68, ballY: 8, velocityX: 0.5, velocityY: 0.2)
        computer.update(held: [])
        XCTAssertEqual(computer.velocityX, -0.525, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(abs(computer.velocityY), 0.9)
        XCTAssertEqual(computer.playerScore, 0)
    }

    func testTetrisClearsCompletedRowsAndRendersScore() {
        var board = Array(repeating: Array(repeating: 0, count: 10), count: 16)
        board[15] = Array(repeating: 1, count: 10)
        board[14] = Array(repeating: 2, count: 10)
        var game = TetrisState(board: board, piece: 3, position: .init(x: 3, y: 0))
        game.update(now: 1, held: [], pressed: [.space])
        XCTAssertEqual(game.score, 2)
        XCTAssertEqual(game.board.count, 16)
        XCTAssertFalse(game.board.contains(where: { $0.allSatisfy { $0 != 0 } }))
        var frame = ArcadeFrame()
        game.render(into: &frame)
        XCTAssertEqual(frame.pixels[14 * 72 + 5], .yellow)
        XCTAssertEqual(frame.pixels[14 * 72 + 6], .yellow)
    }

    func testPongScoresAtBothEdgesAndServesTowardConcedingSide() {
        var game = PongState(ballX: 72, ballY: 8, velocityX: 1)
        game.update(held: [])
        XCTAssertEqual(game.playerScore, 1)
        XCTAssertEqual(game.computerScore, 0)
        XCTAssertEqual(game.ballX, 36)
        XCTAssertLessThan(game.velocityX, 0)
        var frame = ArcadeFrame()
        game.render(into: &frame)
        XCTAssertEqual(frame.pixels[7], .cyan)
        game = PongState(ballX: -1, velocityX: -1, playerScore: game.playerScore)
        game.update(held: [])
        XCTAssertEqual(game.computerScore, 1)
        XCTAssertEqual(game.ballX, 36)
        XCTAssertGreaterThan(game.velocityX, 0)
        game.render(into: &frame)
        XCTAssertEqual(frame.pixels[64], .magenta)
    }

    func testBreakoutLastBrickResetsRound() {
        var bricks = Array(repeating: Array(repeating: false, count: 12), count: 4)
        bricks[0][0] = true
        var game = BreakoutState(ballX: 2, ballY: 1, velocityX: 0.1,
                                 velocityY: 0.1, bricks: bricks, remaining: 1)
        game.update(held: [])
        XCTAssertEqual(game.remaining, 48)
        XCTAssertTrue(game.bricks.allSatisfy { $0.allSatisfy { $0 } })
        XCTAssertEqual(game.ballX, 36)
        XCTAssertEqual(game.ballY, 12)
        XCTAssertLessThan(game.velocityY, 0)
    }
}
