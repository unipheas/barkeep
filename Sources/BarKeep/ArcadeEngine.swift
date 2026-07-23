import Foundation

struct ArcadeColor: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    static let black = ArcadeColor(red: 0, green: 0, blue: 0)
    static let white = ArcadeColor(red: 255, green: 255, blue: 255)
    static let dim = ArcadeColor(red: 28, green: 32, blue: 38)
    static let red = ArcadeColor(red: 255, green: 45, blue: 35)
    static let green = ArcadeColor(red: 45, green: 255, blue: 80)
    static let yellow = ArcadeColor(red: 255, green: 220, blue: 35)
    static let cyan = ArcadeColor(red: 30, green: 240, blue: 255)
    static let magenta = ArcadeColor(red: 240, green: 60, blue: 255)
    static let orange = ArcadeColor(red: 255, green: 120, blue: 25)
}

struct ArcadeFrame: Equatable, Sendable {
    static let width = BusyBarClient.displayWidth
    static let height = BusyBarClient.displayHeight

    private(set) var pixels = Array(
        repeating: ArcadeColor.black,
        count: width * height
    )

    mutating func clear(_ color: ArcadeColor = .black) {
        pixels = Array(repeating: color, count: Self.width * Self.height)
    }

    mutating func set(x: Int, y: Int, color: ArcadeColor) {
        guard x >= 0, x < Self.width, y >= 0, y < Self.height else { return }
        pixels[y * Self.width + x] = color
    }

    mutating func rectangle(x: Int, y: Int, width: Int, height: Int, color: ArcadeColor) {
        for row in y..<(y + height) {
            for column in x..<(x + width) {
                set(x: column, y: row, color: color)
            }
        }
    }
}

enum ArcadeGame: String, CaseIterable, Identifiable, Sendable {
    case snake
    case tetris
    case pong
    case breakout

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var number: Int {
        switch self {
        case .snake: 1
        case .tetris: 2
        case .pong: 3
        case .breakout: 4
        }
    }

    var controls: String {
        switch self {
        case .snake: "Arrow keys"
        case .tetris: "←/→ move · ↑ rotate · ↓ drop · Space hard drop"
        case .pong: "↑/↓ or W/S"
        case .breakout: "←/→ move paddle"
        }
    }

    var color: ArcadeColor {
        switch self {
        case .snake: .green
        case .tetris: .cyan
        case .pong: .magenta
        case .breakout: .orange
        }
    }
}

enum ArcadeKey: Hashable, Sendable {
    case up, down, left, right, space, w, s, restart
}

struct ArcadePoint: Equatable, Sendable {
    var x: Int
    var y: Int
}

struct ArcadeEngine: Sendable {
    private(set) var game: ArcadeGame
    private(set) var frame = ArcadeFrame()

    private var snake = SnakeState()
    private var tetris = TetrisState()
    private var pong = PongState()
    private var breakout = BreakoutState()

    init(game: ArcadeGame) {
        self.game = game
        reset()
    }

    mutating func select(_ game: ArcadeGame) {
        self.game = game
        reset()
    }

    mutating func reset() {
        switch game {
        case .snake: snake.reset()
        case .tetris: tetris.reset()
        case .pong: pong.reset()
        case .breakout: breakout.reset()
        }
        render()
    }

    mutating func update(
        now: TimeInterval,
        held: Set<ArcadeKey>,
        pressed: Set<ArcadeKey>
    ) {
        if pressed.contains(.restart) {
            reset()
            return
        }
        switch game {
        case .snake: snake.update(now: now, pressed: pressed)
        case .tetris: tetris.update(now: now, held: held, pressed: pressed)
        case .pong: pong.update(held: held)
        case .breakout: breakout.update(held: held)
        }
        render()
    }

    private mutating func render() {
        frame.clear()
        switch game {
        case .snake: snake.render(into: &frame)
        case .tetris: tetris.render(into: &frame)
        case .pong: pong.render(into: &frame)
        case .breakout: breakout.render(into: &frame)
        }
    }
}

private struct SnakeState: Sendable {
    private var body: [ArcadePoint] = []
    private var food = ArcadePoint(x: 26, y: 8)
    private var direction = ArcadePoint(x: 1, y: 0)
    private var lastTick: TimeInterval = 0

    mutating func reset() {
        body = (0..<5).map { ArcadePoint(x: 10 - $0, y: 8) }
        food = ArcadePoint(x: 26, y: 8)
        direction = ArcadePoint(x: 1, y: 0)
        lastTick = 0
    }

    mutating func update(now: TimeInterval, pressed: Set<ArcadeKey>) {
        if pressed.contains(.up), direction.y != 1 {
            direction = ArcadePoint(x: 0, y: -1)
        } else if pressed.contains(.down), direction.y != -1 {
            direction = ArcadePoint(x: 0, y: 1)
        } else if pressed.contains(.left), direction.x != 1 {
            direction = ArcadePoint(x: -1, y: 0)
        } else if pressed.contains(.right), direction.x != -1 {
            direction = ArcadePoint(x: 1, y: 0)
        }

        guard now - lastTick >= 0.105 else { return }
        lastTick = now
        let head = ArcadePoint(
            x: body[0].x + direction.x,
            y: body[0].y + direction.y
        )
        let dead = head.x < 0 || head.x >= ArcadeFrame.width / 2
            || head.y < 0 || head.y >= ArcadeFrame.height
            || body.contains(head)
        if dead {
            reset()
            return
        }
        let ate = head == food
        body.insert(head, at: 0)
        if ate {
            placeFood()
        } else {
            body.removeLast()
        }
    }

    private mutating func placeFood() {
        repeat {
            food = ArcadePoint(
                x: Int.random(in: 1..<(ArcadeFrame.width / 2 - 1)),
                y: Int.random(in: 1..<(ArcadeFrame.height - 1))
            )
        } while body.contains(food)
    }

    func render(into frame: inout ArcadeFrame) {
        for (index, point) in body.enumerated().reversed() {
            frame.rectangle(
                x: point.x * 2, y: point.y, width: 2, height: 1,
                color: index == 0 ? .yellow : .green
            )
        }
        frame.rectangle(x: food.x * 2, y: food.y, width: 2, height: 1, color: .red)
    }
}

private struct TetrisState: Sendable {
    private static let shapes: [[UInt16]] = [
        [0x0F00, 0x2222, 0x00F0, 0x4444],
        [0x8E00, 0x6440, 0x0E20, 0x44C0],
        [0x2E00, 0x4460, 0x0E80, 0xC440],
        [0x6600, 0x6600, 0x6600, 0x6600],
        [0x6C00, 0x4620, 0x06C0, 0x8C40],
        [0x4E00, 0x4640, 0x0E40, 0x4C40],
        [0xC600, 0x2640, 0x0C60, 0x4C80],
    ]
    private static let colors: [ArcadeColor] = [
        .black, .cyan,
        ArcadeColor(red: 40, green: 80, blue: 255),
        .orange, .yellow, .green, .magenta, .red,
    ]

    private var board = Array(repeating: Array(repeating: 0, count: 10), count: 16)
    private var piece = 0
    private var rotation = 0
    private var position = ArcadePoint(x: 3, y: -1)
    private var lastTick: TimeInterval = 0
    private var score = 0

    mutating func reset() {
        board = Array(repeating: Array(repeating: 0, count: 10), count: 16)
        score = 0
        lastTick = 0
        spawn()
    }

    mutating func update(
        now: TimeInterval,
        held: Set<ArcadeKey>,
        pressed: Set<ArcadeKey>
    ) {
        if pressed.contains(.left), isValid(x: position.x - 1, y: position.y, rotation: rotation) {
            position.x -= 1
        }
        if pressed.contains(.right), isValid(x: position.x + 1, y: position.y, rotation: rotation) {
            position.x += 1
        }
        let nextRotation = (rotation + 1) % 4
        if pressed.contains(.up), isValid(x: position.x, y: position.y, rotation: nextRotation) {
            rotation = nextRotation
        }
        if pressed.contains(.space) {
            while isValid(x: position.x, y: position.y + 1, rotation: rotation) {
                position.y += 1
            }
            lockPiece()
            return
        }
        let delay = held.contains(.down)
            ? 0.055
            : max(0.22, 0.42 - Double(score) * 0.01)
        if now - lastTick >= delay {
            lastTick = now
            if isValid(x: position.x, y: position.y + 1, rotation: rotation) {
                position.y += 1
            } else {
                lockPiece()
            }
        }
    }

    private func hasCell(piece: Int, rotation: Int, x: Int, y: Int) -> Bool {
        let bit = 15 - (y * 4 + x)
        return (Self.shapes[piece][rotation] >> bit) & 1 == 1
    }

    private func isValid(x: Int, y: Int, rotation: Int) -> Bool {
        for row in 0..<4 {
            for column in 0..<4 where hasCell(
                piece: piece, rotation: rotation, x: column, y: row
            ) {
                let boardX = x + column
                let boardY = y + row
                if boardX < 0 || boardX >= 10 || boardY >= 16 {
                    return false
                }
                if boardY >= 0, board[boardY][boardX] != 0 {
                    return false
                }
            }
        }
        return true
    }

    private mutating func spawn() {
        piece = Int.random(in: 0..<Self.shapes.count)
        rotation = 0
        position = ArcadePoint(x: 3, y: -1)
        if !isValid(x: position.x, y: position.y, rotation: rotation) {
            board = Array(repeating: Array(repeating: 0, count: 10), count: 16)
            score = 0
        }
    }

    private mutating func lockPiece() {
        for row in 0..<4 {
            for column in 0..<4 where hasCell(
                piece: piece, rotation: rotation, x: column, y: row
            ) {
                let y = position.y + row
                if y >= 0 {
                    board[y][position.x + column] = piece + 1
                }
            }
        }
        var row = 15
        while row >= 0 {
            if board[row].allSatisfy({ $0 != 0 }) {
                board.remove(at: row)
                board.insert(Array(repeating: 0, count: 10), at: 0)
                score += 1
            } else {
                row -= 1
            }
        }
        spawn()
    }

    func render(into frame: inout ArcadeFrame) {
        let originX = 26
        frame.clear(.dim)
        frame.rectangle(x: originX - 1, y: 0, width: 22, height: 16, color: .white)
        frame.rectangle(x: originX, y: 0, width: 20, height: 16, color: .black)
        for row in 0..<16 {
            for column in 0..<10 where board[row][column] != 0 {
                frame.rectangle(
                    x: originX + column * 2, y: row, width: 2, height: 1,
                    color: Self.colors[board[row][column]]
                )
            }
        }
        for row in 0..<4 {
            for column in 0..<4 where hasCell(
                piece: piece, rotation: rotation, x: column, y: row
            ) {
                let y = position.y + row
                if y >= 0 {
                    frame.rectangle(
                        x: originX + (position.x + column) * 2,
                        y: y, width: 2, height: 1,
                        color: Self.colors[piece + 1]
                    )
                }
            }
        }
        for pixel in 0..<(score % 12) {
            frame.set(x: 5 + pixel, y: 14, color: .yellow)
        }
    }
}

private struct PongState: Sendable {
    private var ballX = Double(ArcadeFrame.width / 2)
    private var ballY = Double(ArcadeFrame.height / 2)
    private var velocityX = 0.55
    private var velocityY = 0.28
    private var paddle = 6
    private var computer = 6
    private var playerScore = 0
    private var computerScore = 0

    mutating func reset() {
        paddle = 6
        computer = 6
        playerScore = 0
        computerScore = 0
        serve(direction: Bool.random() ? 1 : -1)
    }

    mutating func update(held: Set<ArcadeKey>) {
        if held.contains(.up) || held.contains(.w) { paddle -= 1 }
        if held.contains(.down) || held.contains(.s) { paddle += 1 }
        paddle = min(max(paddle, 1), ArcadeFrame.height - 5)
        if ballY > Double(computer + 2) { computer += 1 }
        if ballY < Double(computer + 1) { computer -= 1 }
        computer = min(max(computer, 1), ArcadeFrame.height - 5)

        ballX += velocityX
        ballY += velocityY
        if ballY <= 1 || ballY >= Double(ArcadeFrame.height - 2) {
            velocityY *= -1
        }
        if ballX >= 2, ballX <= 3,
           ballY >= Double(paddle), ballY <= Double(paddle + 4) {
            velocityX = min(abs(velocityX) + 0.025, 1.25)
            velocityY += (ballY - Double(paddle + 2)) * 0.08
            velocityY = min(max(velocityY, -0.9), 0.9)
        }
        if ballX >= Double(ArcadeFrame.width - 4),
           ballX <= Double(ArcadeFrame.width - 3),
           ballY >= Double(computer), ballY <= Double(computer + 4) {
            velocityX = -min(abs(velocityX) + 0.025, 1.25)
            velocityY += (ballY - Double(computer + 2)) * 0.08
            velocityY = min(max(velocityY, -0.9), 0.9)
        }
        if ballX < 0 {
            computerScore += 1
            serve(direction: 1)
        } else if ballX >= Double(ArcadeFrame.width) {
            playerScore += 1
            serve(direction: -1)
        }
    }

    private mutating func serve(direction: Double) {
        ballX = Double(ArcadeFrame.width / 2)
        ballY = Double(ArcadeFrame.height / 2)
        velocityX = direction * 0.55
        velocityY = Bool.random() ? 0.28 : -0.28
    }

    func render(into frame: inout ArcadeFrame) {
        for y in stride(from: 0, to: ArcadeFrame.height, by: 2) {
            frame.set(x: ArcadeFrame.width / 2, y: y, color: .dim)
        }
        frame.rectangle(x: 2, y: paddle, width: 2, height: 5, color: .cyan)
        frame.rectangle(
            x: ArcadeFrame.width - 4, y: computer,
            width: 2, height: 5, color: .magenta
        )
        frame.rectangle(x: Int(ballX), y: Int(ballY), width: 2, height: 1, color: .white)
        for pixel in 0..<(playerScore % 10) {
            frame.set(x: 7 + pixel, y: 0, color: .cyan)
        }
        for pixel in 0..<(computerScore % 10) {
            frame.set(x: ArcadeFrame.width - 8 - pixel, y: 0, color: .magenta)
        }
    }
}

private struct BreakoutState: Sendable {
    private var ballX = Double(ArcadeFrame.width / 2)
    private var ballY = Double(ArcadeFrame.height - 4)
    private var velocityX = 0.45
    private var velocityY = -0.32
    private var paddle = ArcadeFrame.width / 2 - 6
    private var bricks = Array(repeating: Array(repeating: true, count: 12), count: 4)
    private var remaining = 48

    mutating func reset() {
        paddle = ArcadeFrame.width / 2 - 6
        bricks = Array(repeating: Array(repeating: true, count: 12), count: 4)
        remaining = 48
        resetBall()
    }

    mutating func update(held: Set<ArcadeKey>) {
        if held.contains(.left) { paddle -= 2 }
        if held.contains(.right) { paddle += 2 }
        paddle = min(max(paddle, 1), ArcadeFrame.width - 13)

        ballX += velocityX
        ballY += velocityY
        if ballX <= 1 || ballX >= Double(ArcadeFrame.width - 2) {
            velocityX *= -1
        }
        if ballY <= 1 {
            velocityY = abs(velocityY)
        }
        if ballY >= Double(ArcadeFrame.height - 3),
           ballY <= Double(ArcadeFrame.height - 2),
           ballX >= Double(paddle), ballX <= Double(paddle + 12) {
            velocityY = -abs(velocityY)
            velocityX += (ballX - Double(paddle + 6)) * 0.025
            velocityX = min(max(velocityX, -1.25), 1.25)
        }
        let row = Int(ballY) - 1
        let column = Int(ballX) / 6
        if row >= 0, row < 4, column >= 0, column < 12, bricks[row][column] {
            bricks[row][column] = false
            remaining -= 1
            velocityY *= -1
        }
        if ballY >= Double(ArcadeFrame.height) {
            resetBall()
        }
        if remaining == 0 {
            reset()
        }
    }

    private mutating func resetBall() {
        ballX = Double(ArcadeFrame.width / 2)
        ballY = Double(ArcadeFrame.height - 4)
        velocityX = Bool.random() ? 0.45 : -0.45
        velocityY = -0.32
    }

    func render(into frame: inout ArcadeFrame) {
        let colors: [ArcadeColor] = [.red, .orange, .yellow, .green]
        for row in 0..<4 {
            for column in 0..<12 where bricks[row][column] {
                frame.rectangle(
                    x: column * 6 + 1, y: row + 1,
                    width: 5, height: 1, color: colors[row]
                )
            }
        }
        frame.rectangle(
            x: paddle, y: ArcadeFrame.height - 2,
            width: 12, height: 1, color: .cyan
        )
        frame.rectangle(x: Int(ballX), y: Int(ballY), width: 2, height: 1, color: .white)
        frame.rectangle(x: 0, y: 0, width: ArcadeFrame.width, height: 1, color: .dim)
        frame.rectangle(
            x: 0, y: ArcadeFrame.height - 1,
            width: ArcadeFrame.width, height: 1, color: .dim
        )
        frame.rectangle(x: 0, y: 0, width: 1, height: ArcadeFrame.height, color: .dim)
        frame.rectangle(
            x: ArcadeFrame.width - 1, y: 0,
            width: 1, height: ArcadeFrame.height, color: .dim
        )
    }
}
