# Next.js・Prisma・Drizzle（と Spring Boot 4 の更新）から何を採るか

調査日: 2026-10-04。

**出典の方針。** 版と日付は、その日の npm dist-tags、GitHub release、spring.io の
blog で確かめた。

調査環境の network policy は、いくつかの公式サイト（nextjs.org、prisma.io、
orm.drizzle.team、docs.spring.io）を拒否する。そこで、各 project が GitHub に置く
doc の source を読んで引用を確かめた。

- `vercel/next.js/docs`
- `prisma/docs`
- `drizzle-team/drizzle-orm-docs`
- `spring-projects/*` の antora source

その URL を「(source)」として、公式 URL と並べて挙げる。

Next.js の blog だけは GitHub に source が無い。そこで、GitHub 上の第三者の
mirror で文面を確かめ、mirror であることを明記した。

[`SPRING_FASTAPI_GIN.md`](SPRING_FASTAPI_GIN.md)（2026-08-02）の続編であり、
Spring Boot の基本的な判断はそちらにある。

## 結論

四つの project はどれも「一つの宣言から多くを得る」方向へ進んでいる。
ただし、それぞれ一か所ずつ、真実を推測に委ねている。

| project | 強み | 推測に委ねている所 | kofun-boot の答え |
|---|---|---|---|
| Next.js 16 | colocation、Server Function、streaming、typed routes | route を filesystem で、cache key を compiler で、境界を directive で推測する | route は値、cache key は引数、境界は route table の行 |
| Prisma 7/8 | 一つの schema、commit される migration SQL、shadow DB による drift 検出 | rename を名前の差分で推測し、drift を知るのに DB が要る | key による同定、fold による replay |
| Drizzle | host language の schema、SQL に近い API、一文の relational query | rename を対話で尋ね、snapshot の整合を信頼する | 宣言された rename、gate される投影 |
| Spring Boot 4 | 技術ごとの小さな starter、AOT repository、Modulith の検証 | classpath から構成を推測する | 純粋な capability-pack、印字される `ResolvedBoot` |

## 版と日付

| 対象 | 版 | 日付 | 出典 |
|---|---|---|---|
| Next.js | 16.3.8（latest）、15.5.x は backport | 2026-09-30 | [npm dist-tags](https://registry.npmjs.org/-/package/next/dist-tags) |
| Next.js 16.0 | middleware → proxy、Turbopack 既定、Cache Components | 2025-10-21 | [blog](https://nextjs.org/blog/next-16)、[release](https://github.com/vercel/next.js/releases/tag/v16.0.0) |
| Prisma ORM | 7.10.0（stable）、8.0.0-rc（TypeScript による書き直し） | 2026-08-25、2026-09-30 | [7.10.0](https://github.com/prisma/orm/releases/tag/7.10.0)、[release status](https://www.prisma.io/docs/orm/release-status) |
| Prisma 7.0 | Rust-free client が既定、`prisma.config.ts` | 2025-11-19 | [7.0.0](https://github.com/prisma/orm/releases/tag/7.0.0) |
| Drizzle ORM | 0.45.3（latest）、1.0.0-rc.4（`rc`） | 2026-09-21 | [npm dist-tags](https://registry.npmjs.org/-/package/drizzle-orm/dist-tags) |
| Spring Boot | 4.1.1（GA）、4.2.0-M2 | 2026-08-20、2026-09-25 | [4.1.1](https://spring.io/blog/2026/08/20/spring-boot-4-1-1-available-now/) |
| Spring Modulith | 2.0 GA | 2025-11-21 | [blog](https://spring.io/blog/2025/11/21/spring-modulith-2-0-ga-1-4-5-and-1-3-11-released/) |

注記: 「Next.js 17 が 2026-06-15 に出た」と書く第三者の記事がある。npm の dist-tags
と矛盾するので採らない。

## Next.js 16

### 採るもの

- **colocation。** 一つの route segment に `page`、`layout`、`loading`、`error`、
  `not-found`、`route` を並べる。一つの画面に関わるものが一か所にある。
  kofun-boot は [ADR 6](../adr/0006-a-module-owns-its-whole-vertical.md)（module が
  縦を所有する）でこれを得ている。
  出典: [project structure](https://raw.githubusercontent.com/vercel/next.js/canary/docs/01-app/01-getting-started/02-project-structure.mdx)
- **typed routes。** 15.5 で stable になった。存在しない link が型 error になる。
  kofun-boot の TypeScript client も、存在しない path を TS2345 で拒否している。
  出典: [typedRoutes](https://raw.githubusercontent.com/vercel/next.js/canary/docs/01-app/03-api-reference/05-config/01-next-config-js/typedRoutes.mdx)
- **静的な殻と動的な穴を分ける考え。** Partial Prerendering は、16 で Cache
  Components に統合された。kofun-boot では `view(init)` を build 時に評価した値が殻で、
  `Sub` が穴である（[`TEA.md`](../architecture/TEA.md)）。
- **最初の一時間と dev の速さ。** `create-next-app` から Turbopack と Fast Refresh まで
  の流れである。`boot new` と `boot dev --watch` が同じ位置にある。

### 捨てるもの、その理由

1. **filesystem を route の真実にすること。**
   - 次の意味がファイル名の規約に埋まっている。
     - `[id]`、`[...slug]`、`(group)`、`@slot`、`(.)`
     - layout → template → error → loading → not-found → page という描画の入れ子
   - route table を値として扱うには、`next typegen` のような生成段が別に要る。
   - kofun-boot は endpoint を値として宣言する。
2. **関数呼び出しに見える公開 endpoint。**
   - Next.js の文書は、Server Function を公開 HTTP endpoint として扱い、各関数の
     中で認証・認可・入力検証をせよと書く
     （[use-server](https://raw.githubusercontent.com/vercel/next.js/canary/docs/01-app/03-api-reference/01-directives/use-server.mdx)）。
   - CVE-2025-55182（React2Shell）は 2025-12-03 に公開された CVSS 10.0 の脆弱性
     である。Server Function endpoint への細工した request の deserialization から、
     認証不要の RCE になった
     （[React の告知](https://raw.githubusercontent.com/reactjs/react.dev/main/src/content/blog/2025/12/03/critical-security-vulnerability-in-react-server-components.md)）。
     後続の CVE-2025-55183、55184、67779、CVE-2026-23864 も同じ面から出た。
   - kofun-boot では、呼べる関数はすべて route table の行にする。codec は閉じた和
     から生成し、汎用の object graph deserializer を持たない。
3. **middleware に置いた認可。**
   - CVE-2025-29927（GHSA-f82v-jwr5-mffw、CVSS 9.1、2025-03-21）では、内部の
     再帰防止用 header `x-middleware-subrequest` を外から付けると、middleware を
     丸ごと飛ばせた
     （[advisory](https://github.com/advisories/GHSA-f82v-jwr5-mffw)、
     [postmortem](https://vercel.com/blog/postmortem-on-next-js-middleware-bypass)）。
   - 16 では `middleware` という名前が非推奨になり、`proxy`（`proxy.ts`）に改名
     された。`proxy` は Node.js でだけ動く。Edge で動かす場合は、非推奨のまま
     `middleware.ts` が残る
     （[upgrading to 16 (source)](https://github.com/vercel/next.js/blob/canary/docs/01-app/02-guides/upgrading/version-16.mdx)、
     [message](https://nextjs.org/docs/messages/middleware-to-proxy)）。
   - kofun-boot は、framework の制御信号を利用者の入力と同じ channel に載せない。
     認可は、handler が引数として受け取る構成不能な値（`Principal`）にする。
4. **推測された cache key。**
   - 既定値の変遷:
     - Next 14 は `fetch` を既定で cache した。
     - 15 で反転した（[Next 15](https://nextjs.org/blog/next-15)）。
     - 16 で `cacheComponents` と `"use cache"`、`cacheLife`、`cacheTag` の opt-in
       になった
       （[cacheComponents](https://raw.githubusercontent.com/vercel/next.js/canary/docs/01-app/03-api-reference/05-config/01-next-config-js/cacheComponents.mdx)）。
   - Next.js の blog「Our Journey with Caching」（Sebastian Markbåge、2024-10-24）は
     次のように書いている。この post で実験的な `dynamicIO` が導入された。
     「the developer experience suffered due to the caching defaults and controls
     we provided」
     （[blog](https://nextjs.org/blog/our-journey-with-caching)。nextjs.org は拒否さ
     れたので、GitHub 上の
     [mirror](https://raw.githubusercontent.com/xiaoyu2er/nextjs-i18n-docs/main/content/en/blog/our-journey-with-caching.mdx)
     で確かめた）。
   - 16 の `revalidateTag(tag, profile)` について。引数一つの形は、16.0.0 で削除では
     なく非推奨になった。今の文書では TypeScript の error になる
     （[revalidateTag at v16.0.0](https://raw.githubusercontent.com/vercel/next.js/v16.0.0/docs/01-app/03-api-reference/04-functions/revalidateTag.mdx)）。
   - それでも 2026-09-30 に次の advisory が出た
     （[advisories](https://github.com/vercel/next.js/security/advisories)）。
     - 入れ子の `"use cache"` で、root param の値をまたいで cache が漏れる
       （GHSA-h694-7cp9-m8p3）
     - Draft Mode の内容が漏れる（GHSA-3w37-wq28-93x7）
     - cache poisoning が二件
   - compiler が key を推測すると、入力を一つ見落としたときに漏洩になる。
     kofun-boot の core は純粋で、暗黙に読める cookie、header、param を持たない。
     だから **関数の引数が入力のすべて** であり、引数から作った key は構成上欠けない。
5. **directive による境界。** `"use client"` は module の依存 tree に境界を引く。
   境界がファイルの一行で決まるので、移動や import の変更で境界が動く。
   kofun-boot の境界は shell の種類である。

## Prisma 7 と Prisma 8

### 採るもの

- **一つの schema が唯一の宣言であること。**
- **生成した migration SQL を commit し、review すること。**
  - `migrate dev` は SQL を生成して commit 用に残す。
  - `migrate deploy` は保留中のものを適用するだけである
    （[workflows](https://www.prisma.io/docs/orm/prisma-migrate/workflows/development-and-production)）。
  - kofun-boot では `contracts/migrations.sql` がこれに当たる。手で編集すると gate が
    落ちる。
- **Rust-free への移行が示した教訓。**
  - 6.16.0（2025-09-10）で GA、7.0（2025-11-19）で既定になった。
  - bundle は約 14MB から 1.6MB になった
    （[6.16.0](https://github.com/prisma/orm/releases/tag/6.16.0)）。
  - 生成した client の出力先は、`node_modules` ではなく source の中になった。
    生成物は見える場所に置くべきだという判断であり、kofun-boot の
    `contracts/` と同じ考えである。
- **Prisma 8 の contract と `db sign`。** Prisma 8 は 2026-10-04 時点でまだ
  release candidate で（npm の `latest` は `8.0.0-rc.19`）、GA は「2026 年 10 月の
  見込み」である
  （[release status (source)](https://github.com/prisma/docs/blob/main/apps/docs/content/docs/orm/release-status.mdx)）。
  - contract に content hash を持たせる。
  - `prisma contract emit` は contract の各部分に hash（`storageHash`、
    `profileHash`）を付ける。`db sign` は、DB が contract を満たすことを確かめてから、
    その hash を DB の「signature」として記録する。PostgreSQL では
    `prisma_contract.marker` table の一行で、error code では marker と呼ばれる
    （[contract (source)](https://github.com/prisma/docs/blob/main/apps/docs/content/docs/orm/contract-authoring/the-contract-artifact.mdx)）。
  - これで application と DB の整合を検査する
    （[contract](https://www.prisma.io/docs/orm/v8/contract-authoring/the-contract-artifact)、
    [TS migrations](https://www.prisma.io/blog/typescript-migrations-in-prisma-next)）。
  - kofun-boot では「DB が自分の schema digest を持ち、binary が起動時に比べる」
    という issue にした（[#51](https://github.com/kofun-lang/kofun-boot/issues/51)）。
- **Prisma 8 の ADR 003「一 query 一文」** は、N+1 の扱いで最も近い立場である
  （[`N_PLUS_ONE.md`](N_PLUS_ONE.md) を参照）。

### 捨てるもの、その理由

1. **名前による rename の推測。** 名前が消えて別の名前が現れると、drop + add として
   生成し、data loss を警告する。kofun-boot は column を key で同定する
   （[ADR 8](../adr/0008-a-column-is-its-key.md)）。
2. **drift を知るための shadow database。**
   - `migrate dev` は history を shadow DB に流して drift を検出する
     （[shadow database](https://www.prisma.io/docs/orm/v7/prisma-migrate/understanding-prisma-migrate/shadow-database)）。
   - kofun-boot では history は fold であり、drift は二つの値の比較である
     （[ADR 9](../adr/0009-a-migration-history-is-a-fold.md)）。
   - 本物の DB は、SQL 投影が意味を保っているかの検査にだけ使う。
3. **専用 DSL。** `schema.prisma` は TypeScript でも SQL でもない第三の言語である。
   kofun-boot の schema は Kofun の値である。
4. **型推論に live DB が要る TypedSQL（preview）。**
   （[TypedSQL](https://www.prisma.io/docs/orm/v7/prisma-client/using-raw-sql/typedsql)）。
   build に DB を要求すると、build が環境に依存する。

## Drizzle

### 採るもの

- **host language の schema。** 型は `$inferSelect` と `$inferInsert` で推論され、
  codegen が要らない（[goodies](https://orm.drizzle.team/docs/goodies)）。
  - kofun-boot の schema も host language の値である。
  - ただし Kofun には型 level の計算が無い。そこで行の型は build 時の投影にし、
    gate で drift を拒否する。
- **「If you know SQL, you know Drizzle」。** 依存 0 であること
  （[overview](https://raw.githubusercontent.com/drizzle-team/drizzle-orm-docs/main/src/content/docs/overview.mdx)）。
  生成される SQL が予測できることは、R5 [#20](https://github.com/kofun-lang/kofun-boot/issues/20)
  の bar と同じである。
- **relational query は常に一文。** lateral join と JSON 集約を使う
  （[rqb](https://orm.drizzle.team/docs/rqb)）。kofun-boot の宣言 shape の
  compile 先である。
- **schema から validator を作ること。** `drizzle-zod` は 1.0 beta で
  `drizzle-orm/zod` に統合された
  （[zod](https://raw.githubusercontent.com/drizzle-team/drizzle-orm-docs/main/src/content/docs/zod.mdx)）。
  kofun-boot では、endpoint の validation sum を schema から投影する。
- **決定的な seed。** `drizzle-seed` は seed 値を与えた pRNG で、同じ seed から同じ
  data を作る
  （[drizzle-seed](https://raw.githubusercontent.com/drizzle-team/drizzle-orm/main/drizzle-seed/README.md)）。
  kofun-boot の mock は既に、id を値から割り当て、seed を digest で固定している。
- **migration ごとの folder。** v1 では journal をやめ、migration ごとに SQL と
  snapshot を一つの folder に置く。git の conflict を減らすためである。

### 捨てるもの、その理由

1. **rename の対話。** `drizzle-kit generate` の文書は「prompt developer for renames
   if necessary」と書く
   （[generate (source)](https://github.com/drizzle-team/drizzle-orm-docs/blob/main/src/content/docs/pg/drizzle-kit-generate.mdx)）。
   実際の問いは drizzle-kit の source にあり、「Is {column} column in {table} table
   created or renamed from another column?」である
   （[views.ts](https://github.com/drizzle-team/drizzle-orm/blob/main/drizzle-kit/src/cli/views.ts)）。
   CI には答える人が
   いない。kofun-boot では rename は history に宣言された step である。
2. **`push` による file 無しの同期。** 試作には速いが、history が残らない。
   kofun-boot の history は fold の入力そのものなので、省略できない。
3. **snapshot を信頼すること。** snapshot JSON と SQL が一致しているかは、snapshot
   自身では分からない。kofun-boot は投影を毎回作り直し、本物の DB で二通りの
   SQL を比べる。
4. **1.0 前であること。** 1.0 は 2026-10 時点で rc である。API の形は参考にするが、
   互換性の主張には使わない。

## Spring Boot 4 の更新

- **小さな技術別 starter（4.0、2025-11-20）。** auto-configuration が技術ごとの
  module に分かれた
  （[migration guide](https://github.com/spring-projects/spring-boot/wiki/Spring-Boot-4.0-Migration-Guide)）。
  kofun-boot の starter は、純粋な capability-pack 関数である
  （R2 [#17](https://github.com/kofun-lang/kofun-boot/issues/17)）。
- **API versioning と HTTP service client（`@HttpExchange`）。** interface から
  client を作る。kofun-boot は route table から client を投影している。
- **Spring Data AOT repository。** query method を build 時に source として生成し、
  起動時の reflection を無くす
  （[blog](https://spring.io/blog/2025/05/22/spring-data-ahead-of-time-repositories/)）。
  「導出は build 時に」という kofun-boot の原則と同じ方向である。
- **Spring Modulith 2.0。**
  - `verify()` で module 間の循環と、API package 以外への参照を拒否する。
  - Event Publication Registry は、業務 transaction の中に event を記録する。
  - 前者は kofun-boot の `scripts/check-modules.sh` が既に持つ。後者は L12 の outbox
    として採る。
- **Testcontainers と `@ServiceConnection`。** container を接続情報の bean にする
  （[blog](https://spring.io/blog/2023/06/23/improved-testcontainers-support-in-spring-boot-3-1)）。
  kofun-boot では DB は capability なので、配線は record の field の差し替えである。
  本物の DB は `tests/schema/postgres.sh` で投影の検査にだけ使う。

## その他（短く）

- **Atlas。**
  - 宣言的な schema 管理（Terraform のように、現在と目標の差分を取る）と、
    versioned migration がある。
  - `atlas.sum` は migration ごとの checksum と全体の sum を持つ。原文の言葉では
    「a reverse, one branch merkle hash tree」で、編集を検出する。この文書は v0.29.0 で
    ariga/atlas の repository から外れたので、v0.28.0 の版を引く
    （[v0.28.0](https://raw.githubusercontent.com/ariga/atlas/v0.28.0/doc/md/concepts/migration-directory-integrity.md)、
    [dir.go](https://github.com/ariga/atlas/blob/master/sql/migrate/dir.go)）
    （[integrity](https://atlasgo.io/concepts/migration-directory-integrity)）。
  - kofun-boot は、release ごとに history の prefix を固定する案として採る。
- **sqlc と Kysely。**
  - sqlc は SQL を書き、型付き interface を生成する
    （[sqlc](https://github.com/sqlc-dev/sqlc)）。
  - Kysely は codegen 無しの型付き query builder である
    （[Kysely](https://github.com/kysely-org/kysely)）。
  - kofun-boot の query 値は、二つの間にある。値として書き、build 時に SQL と
    codec へ compile する。
- **Ecto。** changeset で受け入れる field を明示する。`Ecto.Multi` は、実行せずに
  検査できる transaction の値である。kofun-boot の transaction capability の手本である。
- **Convex。**
  - query は同じ引数に同じ答えを返す。
  - mutation は決定的でなければならない。
  - 衝突したら transaction を再実行する
    （[OCC](https://raw.githubusercontent.com/get-convex/convex-backend/main/npm-packages/docs/docs/database/advanced/occ.mdx)）。

  決定性を前提にした再実行は、kofun-boot の replay と同じ考えである。
- **Encore。** code の中で宣言した resource から infrastructure を作る
  （[Encore](https://github.com/encoredev/encore)）。kofun-boot の capability manifest
  は、その「宣言の印字」の側に当たる。

## 採用・適応・不採用

| 判定 | 項目 | 理由 |
|---|---|---|
| adopt | Prisma の commit される migration SQL | review する人は、走る SQL を読むべきである |
| adopt | Drizzle の host language schema と一文の relational query | DSL と隠れた N+1 を両方避けられる |
| adopt | drizzle-seed の決定的 seed | replay の前提である |
| adopt | Prisma 8 の contract digest を DB に書く案 | binary と DB の不整合を起動時に拒否できる |
| adapt | Next.js の colocation | filesystem ではなく module の所有で得る |
| adapt | Next.js の cache tag と寿命 | 推測ではなく宣言にし、manifest に印字する |
| adapt | Prisma の shadow DB | fold に置き換える。本物の DB は投影の検査だけに使う |
| adapt | Spring Modulith の検証と event registry | 既存の module gate と L12 の outbox にする |
| reject | filesystem を route の真実にすること | route table を値として検査も投影もできない |
| reject | 名前の差分による rename の推測、対話による確認 | CI に人はいない。誤推測は data を壊す |
| reject | middleware による認可 | 飛ばせる層に認可を置くことになる |
| reject | 汎用 deserializer が付いた server 呼び出し | 外部から呼べる面が見えなくなる |
| reject | compiler が推測する cache key | 入力の見落としが漏洩になる |

## 実装へ落ちる項目

- **L7（今回実装、[#45](https://github.com/kofun-lang/kofun-boot/issues/45)）。** schema の値、key による同定、fold による replay、
  key による planner、policy の強制、SQL 投影、本物の PostgreSQL との照合。
  - `modules/schema`
  - `tests/schema/check.sh`
  - `tests/schema/postgres.sh`
- **L7（今回実装、[#46](https://github.com/kofun-lang/kofun-boot/issues/46)）。** round の合流と、N に依存しない文数の gate。
  - `modules/loader`
  - `tests/loader/check.sh`
- **L7（issue）。**
  - 複数 table と外部 key: [#47](https://github.com/kofun-lang/kofun-boot/issues/47)
  - 型変更の migration: [#48](https://github.com/kofun-lang/kofun-boot/issues/48)
  - 宣言 shape の `LATERAL` compile: [#49](https://github.com/kofun-lang/kofun-boot/issues/49)
  - 型付き query 値と row codec: [#50](https://github.com/kofun-lang/kofun-boot/issues/50)
  - DB の digest marker: [#51](https://github.com/kofun-lang/kofun-boot/issues/51)
  - release ごとの history 固定: [#52](https://github.com/kofun-lang/kofun-boot/issues/52)
  - data migration: [#53](https://github.com/kofun-lang/kofun-boot/issues/53)
- **L1 と L3（issue）。** `Principal` capability（[#54](https://github.com/kofun-lang/kofun-boot/issues/54)）と生成 codec（[#55](https://github.com/kofun-lang/kofun-boot/issues/55)）。
- **L2 と L11（issue）。** 宣言 cache（[#56](https://github.com/kofun-lang/kofun-boot/issues/56)）。
- **L8（issue）。** `boot db plan / check / sql`（[#57](https://github.com/kofun-lang/kofun-boot/issues/57)）。
