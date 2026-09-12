import Foundation

struct IntPoint: Hashable, Codable {
    var x: Int
    var y: Int
}

struct IntRect: Equatable, Codable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    func contains(_ p: IntPoint) -> Bool {
        p.x >= x && p.y >= y && p.x < x + width && p.y < y + height
    }
}

struct CollisionMap {
    let tileSize: Int
    let width: Int
    let height: Int
    private let blocked: Set<IntPoint>

    init(tileSize: Int = 16, width: Int, height: Int, blocked: Set<IntPoint>) {
        self.tileSize = tileSize
        self.width = width
        self.height = height
        self.blocked = blocked
    }

    func isBlocked(worldX: Double, worldY: Double) -> Bool {
        let tx = Int(floor(worldX / Double(tileSize)))
        let ty = Int(floor(worldY / Double(tileSize)))
        guard tx >= 0, ty >= 0, tx < width, ty < height else { return true }
        return blocked.contains(IntPoint(x: tx, y: ty))
    }
}

struct PortraitCamera {
    static let logicalWidth: Double = 240
    static let logicalHeight: Double = 520

    var centerX: Double
    var centerY: Double
    var worldBounds: IntRect

    mutating func follow(x: Double, y: Double) {
        let halfW = Self.logicalWidth / 2
        let halfH = Self.logicalHeight / 2
        let minX = Double(worldBounds.x) + halfW
        let maxX = Double(worldBounds.x + worldBounds.width) - halfW
        let minY = Double(worldBounds.y) + halfH
        let maxY = Double(worldBounds.y + worldBounds.height) - halfH
        centerX = minX <= maxX ? min(max(x, minX), maxX) : Double(worldBounds.x + worldBounds.width / 2)
        centerY = minY <= maxY ? min(max(y, minY), maxY) : Double(worldBounds.y + worldBounds.height / 2)
    }
}
