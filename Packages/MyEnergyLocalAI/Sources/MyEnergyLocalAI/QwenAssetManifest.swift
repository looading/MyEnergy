import Foundation

/// 固定发布资产；所有名称、长度和 SHA-256 都经过源文件或 HF 元数据核对。
public enum QwenAssetManifest {
  public static let modelID = "qwen3.1.7b.4bit"
  public static let repository = "mlx-community/Qwen3-1.7B-4bit"
  public static let revision = "3b1b1768f8f8cf8351c712464f906e86c2b8269e"
  public static let licenseRevision = "70d244cc86ccca08cf5af4e1e306ecf908b1ad5e"

  public struct Asset: Sendable {
    public let name: String
    public let bytes: Int64
    public let sha256: String
    public let url: URL
  }

  public static let assets: [Asset] = [
    asset("README.md", 873, "26afc7609fa8dce8a0763b115ce95017763e45c0aaa92ac38911363f4fc1c16b"),
    asset("added_tokens.json", 707, "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680"),
    asset("config.json", 937, "507a6701220524eb8b283425bf0856a9ae4f21f4052e563896ddd668994b1dc7"),
    asset("merges.txt", 1_671_853, "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
    asset("model.safetensors", 968_080_210, "0e86d9677e519323849eac1bc272caae88567a481ff188c431f70be543d9995f"),
    asset("model.safetensors.index.json", 49_731, "1e3058d4ba4b04e4de35b74467725cbef90ff022198404218e48f21adc9cfa15"),
    asset("special_tokens_map.json", 613, "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"),
    asset("tokenizer.json", 11_422_654, "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
    asset("tokenizer_config.json", 9_706, "253153d0738ceb4c668d2eff957714dd2bea0b56de772a9fdccd96cbf517e6a0"),
    asset("vocab.json", 2_776_833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
    Asset(name: "LICENSE", bytes: 11_343,
          sha256: "832dd9e00a68dd83b3c3fb9f5588dad7dcf337a0db50f7d9483f310cd292e92e",
          url: URL(string: "https://huggingface.co/Qwen/Qwen3-1.7B/resolve/\(licenseRevision)/LICENSE")!)
  ]

  public static var totalBytes: Int64 { assets.reduce(0) { $0 + $1.bytes } }

  private static func asset(_ name: String, _ bytes: Int64, _ sha256: String) -> Asset {
    Asset(name: name, bytes: bytes, sha256: sha256,
          url: URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(name)")!)
  }
}
