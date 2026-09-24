// MARK: - 小游戏：接零食（SwiftUI 实现）
import SwiftUI

struct GameView: View {
    @EnvironmentObject var dataManager: DataManager
    @State private var gameState: GameState = .idle
    @State private var playerX: CGFloat = 0
    @State private var items: [GameItem] = []
    @State private var score: Int = 0
    @State private var timeLeft: Int = 60
    @State private var showResult = false
    @State private var earnedFood: Int = 0

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                if gameState == .idle {
                    startView
                } else if gameState == .playing {
                    gameView
                } else if showResult {
                    resultView
                }
            }
        }
    }

    // MARK: - 开始界面
    private var startView: some View {
        VStack(spacing: 24) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 80))
                .foregroundColor(.orange)

            Text("接零食")
                .font(.title)
                .fontWeight(.heavy)

            Text("滑动控制宠物篮子，接住掉落的零食！")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Text("当前食物：\(dataManager.getPetFood()) 🍙")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Button {
                startGame()
            } label: {
                Text("开始游戏")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.orange)
                    .cornerRadius(16)
            }
            .padding(.horizontal, 60)
        }
        .padding()
    }

    // MARK: - 游戏中
    private var gameView: some View {
        ZStack {
            // 游戏画布
            Canvas { context, size in
                // 背景
                context.fill(Rectangle().path(in: CGRect(x: 0, y: 0, width: size.width, height: size.height)),
                           style: PaintColor(Color(.systemGray6)))

                // 玩家（篮子）
                let playerY = size.height - 60
                let playerWidth: CGFloat = 80
                let playerRect = CGRect(x: playerX - playerWidth/2, y: playerY, width: playerWidth, height: 40)
                context.fill(Ellipse().path(in: playerRect), style: PaintColor(Color.orange))

                // 零食
                for item in items {
                    let itemRect = CGRect(x: item.x - 15, y: item.y, width: 30, height: 30)
                    context.fill(Ellipse().path(in: itemRect), style: PaintColor(Color.purple.opacity(0.8)))
                }
            }
            .gesture(DragGesture().onChanged { value in
                playerX = max(40, min(value.location.x, UIScreen.main.bounds.width - 40))
            })

            // HUD
            VStack {
                HStack {
                    Text("得分：\(score)")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                    Text("时间：\(timeLeft)s")
                        .font(.headline)
                        .foregroundColor(timeLeft <= 10 ? .red : .primary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Spacer()

                Button("结束") {
                    endGame()
                }
                .buttonStyle(.bordered)
                .padding(.bottom, 20)
            }
        }
        .frame(height: 400)
        .onAppear { startGameLoop() }
        .onDisappear { stopGameLoop() }
    }

    // MARK: - 结果界面
    private var resultView: some View {
        VStack(spacing: 20) {
            Text("游戏结束！")
                .font(.title)
                .fontWeight(.heavy)

            Text("得分：\(score)")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(.orange)

            Text("获得 \(earnedFood) 个食物 🍙")
                .font(.body)
                .foregroundColor(.secondary)

            Button {
                var state = dataManager.loadState()
                state.pet.food += earnedFood
                state.pet.mood = min(100, state.pet.mood + 5)
                dataManager.saveState(state)
                showResult = false
                gameState = .idle
                score = 0
                timeLeft = 60
                items.removeAll()
            } label: {
                Text("领取奖励")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.green)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 60)

            Button("再玩一次") {
                score = 0
                timeLeft = 60
                items.removeAll()
                showResult = false
                gameState = .playing
                startGameLoop()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - 游戏逻辑
    private func startGame() {
        gameState = .playing
        score = 0
        timeLeft = 60
        items.removeAll()
        playerX = UIScreen.main.bounds.width / 2
    }

    private func endGame() {
        gameState = .idle
        stopGameLoop()
        showResult = true
        earnedFood = min(score / 5, 10)
    }

    private var gameTimer: Timer?
    private var spawnTimer: Timer?
    private var displayLink: CADisplayLink?

    private func startGameLoop() {
        // 倒计时
        gameTimer?.invalidate()
        gameTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.gameState == .playing else { return }
            self.timeLeft -= 1
            if self.timeLeft <= 0 {
                self.endGame()
            }
        }

        // 生成零食
        spawnTimer?.invalidate()
        spawnTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            self?.spawnItem()
        }

        // 渲染循环
        displayLink?.invalidate()
        displayLink = CADisplayLink(target: self, selector: #selector(frameUpdate))
        displayLink?.add(to: .main, forMode: .default)
    }

    private func stopGameLoop() {
        gameTimer?.invalidate()
        spawnTimer?.invalidate()
        displayLink?.invalidate()
        gameTimer = nil
        spawnTimer = nil
        displayLink = nil
    }

    @objc private func frameUpdate() {
        guard gameState == .playing else { return }

        let screenBounds = UIScreen.main.bounds
        var captured: [GameItem] = []
        let playerY = screenBounds.height - 60
        let playerWidth: CGFloat = 80

        for item in items {
            let newY = item.y + item.speed
            let itemRect = CGRect(x: item.x - 15, y: newY, width: 30, height: 30)
            let playerRect = CGRect(x: playerX - playerWidth/2, y: playerY, width: playerWidth, height: 40)

            if itemRect.intersects(playerRect) {
                score += 1
                continue
            }
            if newY > screenBounds.height {
                continue
            }
            captured.append(GameItem(x: item.x, y: newY, speed: item.speed))
        }
        items = captured
    }

    private func spawnItem() {
        let x = CGFloat.random(in: 40...UIScreen.main.bounds.width - 40)
        items.append(GameItem(x: x, y: -30, speed: CGFloat.random(in: 2...4)))
    }
}

struct GameItem {
    var x: CGFloat
    var y: CGFloat
    var speed: CGFloat
}

enum GameState {
    case idle
    case playing
}
