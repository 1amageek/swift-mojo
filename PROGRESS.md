# Progress

- [x] MWR-1 単一immutable input resourceの公開identity・bounded private admission・固定environment・既存worker lifetimeへの統合を実装し、admission 15 tests、Jetson native C backend成功/拒否経路、および同一designerの契約reviewを完了 `depends:none` `parallel:none`
- [ ] MWR-2 MWR-1の公開契約、source audit、focused unit/integration tests、既存resource-free worker回帰、resource-required factoryの実process成功/欠落失敗、Macとnative Linuxの実worker acceptanceを一度の設計適合reviewで統合し、protocol v1・factory ABI・W2 strict bundle layout・deadline/cancel/crash isolationと下流consumerのfilesystem/POSIX非依存を確認する `depends:MWR-1` `parallel:none`
