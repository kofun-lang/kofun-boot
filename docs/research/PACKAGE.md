# kofun-boot framework research pack

スナップショット日: 2026-10-04

この ZIP は、kofun-boot の設計を支える調査と、そこから採った決定を一つにまとめた
成果物である。

- **調査**:
  - Spring Boot / FastAPI / Gin を中心とする Web framework の比較
  - Next.js・Prisma・Drizzle の比較
  - N+1 を避ける全手法（ORM、query compiler、DataLoader、Haxl などの関数型手法）
  - modular-monolith-with-ddd の DDD 戦術パターン
  - desktop、effect、rendering の調査
- **決定**:
  - architecture decision（`docs/architecture/`）
  - 番号付きの ADR（`docs/adr/`）

## 最短の読み順

1. `docs/architecture/BLUEPRINT.md`: 全体の設計図。各層について、取るもの・捨てるもの・gate を書いている
2. `docs/research/SPRING_FASTAPI_GIN.md`
3. `docs/research/NEXT_PRISMA_DRIZZLE.md`
4. `docs/research/N_PLUS_ONE.md`
5. `docs/architecture/DATA.md`
6. `docs/research/MODULAR_MONOLITH_DDD.md`
7. `docs/architecture/FDDD.md`
8. `docs/architecture/EFFECTS.md`
9. `docs/architecture/TEA.md`
10. `docs/ROADMAP.md`

残りの文書の役割は次のとおり。

- `docs/research/WEB_FRAMEWORKS.md`: 対象を広げた比較
- `DESKTOP_FRAMEWORKS.md`、`RENDER_BACKENDS.md`: desktop lane
- `EFFECT_SYSTEMS.md`: effect model の根拠
- `docs/adr/`: 一つずつの決定と、その代償

## 検証

ZIP 直下の `MANIFEST.sha256` は、manifest 自身を除く全収録ファイルの SHA-256 を持つ。

```sh
unzip kofun-boot-framework-research-2026-10-04.zip
cd kofun-boot-framework-research-2026-10-04
sha256sum -c MANIFEST.sha256
```

repository から同じ成果物を再生成する場合:

```sh
sh scripts/build-research-pack.sh dist
sh tests/research/check.sh
```

生成 script は、収録順・timestamp・ZIP の extra field を固定する。日付は
`scripts/build-research-pack.sh` の一か所でだけ定義し、gate はその script に名前を
尋ねる。

gate は次のことを確かめる。

- 通常環境と `env -i` で二回生成し、ZIP と digest が byte 単位で一致する。
- `docs/research/`、`docs/adr/`、`docs/architecture/` の全 Markdown が、pack に
  入っているか、理由付きで除外されている。どちらでもない文書は、ファイル名を
  名指しして失敗する。

## 境界

- 外部 repository の source code や Web page の本文は再配布しない。収録するのは、
  出典 URL、commit pin、要約、設計判断である。
- 外部 benchmark の数値は kofun-boot の性能値ではない。kofun-boot の比較値は、
  同じ box・同じ handler で L5 gate が測るまで未測定である。
- **実装済みのもの:**
  - module の縦割り ownership
  - contract-only dependency gate
  - closed business outcome seed
  - schema の値と、fold としての migration history（`modules/schema`）
  - round の合流と、N に依存しない文数の gate（`modules/loader`）
- **調査・設計段階のもの:** 次のものは、すべてが実装済みという意味ではない。各文書の
  adopt/adapt/defer と、ROADMAP の issue を参照すること。
  - Outbox / Inbox
  - module 別の database schema
  - event sourcing
  - 型付き query
  - 宣言 cache
  - `Principal`
- 調査環境の network policy で、一部の公式サイトには届かなかった。届かなかった場合
  は、同じ文書の GitHub 上の source を読み、その URL を併記した。それも出来なかった
  主張には、各文書で印を付けている。

## License

この pack 内の kofun-boot 文書は、repository と同じ Apache-2.0 OR MIT である。
リンク先の資料・project には、それぞれの license と利用条件が適用される。
