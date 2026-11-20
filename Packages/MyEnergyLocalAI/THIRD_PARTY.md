# 第三方声明

本文件记录固定直接依赖和模型来源。正式分发时还须依据 root 保存的完整 `Package.resolved` 补齐所有实际传递依赖的声明；本轮没有完成分发许可清单验收。

| 内容 | 固定版本 | 许可证与来源 |
| --- | --- | --- |
| Qwen3-1.7B 模型 | 官方 revision `70d244cc86ccca08cf5af4e1e306ecf908b1ad5e` | [Apache License 2.0 原文](https://huggingface.co/Qwen/Qwen3-1.7B/blob/70d244cc86ccca08cf5af4e1e306ecf908b1ad5e/LICENSE)；下载后原样保留为 `LICENSE` |
| MLX Community 量化转换 | revision `3b1b1768f8f8cf8351c712464f906e86c2b8269e` | [发布者 README](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit/blob/3b1b1768f8f8cf8351c712464f906e86c2b8269e/README.md) 声明 Apache 2.0，并指向 Qwen 模型许可；下载后保留该 README |
| MLX Swift | `0.29.1` | [MIT](https://github.com/ml-explore/mlx-swift/blob/0.29.1/LICENSE)，Copyright (c) 2023 ml-explore |
| MLX Swift LM | `2.29.3` | [MIT](https://github.com/ml-explore/mlx-swift-lm/blob/2.29.3/LICENSE)，Copyright (c) 2024 ml-explore |
| Swift Transformers | `1.1.6` | [许可证原文](https://github.com/huggingface/swift-transformers/blob/1.1.6/LICENSE)；以固定仓库文件为准，包含 Hub／Tokenizers 相关实现 |

MLX Swift 与 MLX Swift LM 的 MIT 许可正文如下，其版权声明分别如上：

```text
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
