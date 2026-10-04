# kofun-boot 設計図: Spring Boot・Next.js・Prisma・Drizzle から何を取り、何を捨てるか

日付: 2026-10-04。根拠となる調査は次の三つである。

- [`docs/research/NEXT_PRISMA_DRIZZLE.md`](../research/NEXT_PRISMA_DRIZZLE.md)
- [`docs/research/N_PLUS_ONE.md`](../research/N_PLUS_ONE.md)
- [`docs/research/SPRING_FASTAPI_GIN.md`](../research/SPRING_FASTAPI_GIN.md)

各層の詳しい決定は [`DATA.md`](DATA.md)、[`EFFECTS.md`](EFFECTS.md)、
[`TEA.md`](TEA.md)、[`FDDD.md`](FDDD.md) と ADR 8〜10 にある。

この文書は全体の地図である。各層について、次の五つを書く。

- 参考元から何を取るか
- 何を捨てるか
- kofun-boot での形
- それを守る gate
- 今どこまで動くか

「最高の framework」は願望なので、そのままでは設計にならない。
この文書では、そう呼べる条件を **測れる bar の集合** として書く。

## 一文の設計

> **アプリケーションは、capability から振る舞いへの純粋関数である。**
> **kofun-boot は、それを配線し、配信し、再生し、測定する shell である。**

以下はすべて、この一文から導かれる。

## 七つの原則

| # | 原則 | 何から学んだか | 何を禁じるか |
|---|---|---|---|
| 1 | **一つの宣言、多くの投影** | FastAPI、Prisma schema、Drizzle、servant | 手書きの OpenAPI、手書きの migration SQL、手書きの client |
| 2 | **capability は引数** | Spring DI を裏返したもの | IoC container、classpath scan、reflection |
| 3 | **effect はデータ** | Elm、Haxl | core からの I/O、lazy loading、隠れた await |
| 4 | **決定的 replay** | Kofun の tzdb gate、Convex | 時計・乱数・環境変数への暗黙の依存 |
| 5 | **拒否は答えである** | Functional DDD | 例外による業務ルール、default arm |
| 6 | **既定値は印字される** | Spring Boot の conditions report | 黙った `0.0.0.0` bind、推測された設定 |
| 7 | **主張には gate がある** | Kofun の言語 repository | 測っていない数値、壊して確かめていない gate |

## 全体図

```
               ┌──────────────────────── 一つの宣言 ─────────────────────────┐
               │  endpoint table   schema value   query shape   capability set │
               └──────┬───────────────┬──────────────┬───────────────┬──────────┘
          build 時の投影│               │              │               │
   ┌──────────────────▼──┐ ┌──────────▼────────┐ ┌───▼────────────┐ ┌▼──────────────────┐
   │ dispatch / OpenAPI / │ │ DDL / migration   │ │ 文数の確定した  │ │ 起動時に印字する  │
   │ typed client         │ │ SQL / row type    │ │ SQL (LATERAL)   │ │ manifest / explain│
   └──────────────────────┘ └───────────────────┘ └────────────────┘ └───────────────────┘
                                         │
   ┌─────────────────────────────────────▼─────────────────────────────────────┐
   │ functional core: init / update / view / subscriptions (すべて純粋)        │
   │   Msg を受け取り、Model と Cmd（不活性なデータ）を返す                    │
   └─────────────────────────────────────┬─────────────────────────────────────┘
                                         │ Cmd: 一 round 分の要求をまとめて
   ┌─────────────────────────────────────▼─────────────────────────────────────┐
   │ imperative shell: capability を持つ唯一の層                               │
   │   coalesce (source ごとに一文、key は一度だけ) → 実行 → Msg を返す         │
   │   trace に全 round を記録 → replay / N+1 検査 / 回帰比較                  │
   └───────────────────────────────────────────────────────────────────────────┘
```

## 1. Contract と routing — 真実は directory ではなく値に置く

**Next.js App Router から取るもの。** colocation である。
`page`、`layout`、`loading`、`error`、`route` を同じ segment に並べると、
一つの画面に関わるものが一か所に集まる。そのため、新しく来た人でも迷わない。
Next.js 15.5 では typed routes が stable になった。存在しない link が
compile error になるのは正しい方向である。

**捨てるもの。** route の真実を filesystem に置くことである。
次のような意味が、ファイル名と directory 名の規約に埋め込まれている。

- `[id]`、`[...slug]`、`(group)`、`@slot`、`(.)`
- page、layout、template、error、loading、not-found の描画順

そのため、route table を値として検査したり投影したりするには、別の生成段階
（`next typegen`）が要る。
kofun-boot は endpoint を **値** として宣言する（tapir や Elysia/Eden の系統）。
同じ table から次の四つを投影する。

- dispatch
- validation
- OpenAPI
- typed client

colocation は [ADR 6](../adr/0006-a-module-owns-its-whole-vertical.md) の
「module が縦を所有する」で既に得ている。

**gate。** `tests/boot/check.sh` が二つを読む。

- router が自分で印字した 20 行の表
- その表から投影した OpenAPI と TypeScript client

存在しない route を呼ぶ client code は TS2345 で落ちる。**今日成立している。**

## 2. Server Function と境界 — 見えない endpoint を作らない

**Next.js から学ぶこと。** Server Function（旧 Server Actions）は、関数呼び出しに
見える **公開 HTTP endpoint** である。Next.js 自身の文書も、各関数の中で
認証・認可・入力検証をせよと書いている。

2025-12-03 に公開された CVE-2025-55182（React2Shell、CVSS 10.0）は、
Server Function endpoint に届く Flight protocol の deserialization から生じた、
認証不要の RCE だった。「関数呼び出しに見える」ことは、二つのものを見えなくする。

- 外部から呼べる面
- 任意の object graph を復元する deserializer

**kofun-boot の形。**

- 呼べる server 側の関数は **すべて route table の行** である。OpenAPI、client、
  capability manifest にも同じ行が出る。表に無い関数は呼べない。
- wire 上の codec は、contract の閉じた和から build 時に生成する。未知の
  constructor tag は型付きの拒否（`Malformed(tag)`）になる。参照、Promise、
  thenable、class instance を復元する汎用 deserializer は持たない。

**状態。** route table と projection は成立している。codec 生成は [#55](https://github.com/kofun-lang/kofun-boot/issues/55)。

## 3. 認可 — middleware ではなく、構成できない値にする

**Next.js から学ぶこと。** CVE-2025-29927（CVSS 9.1、2025-03-21）では、内部の
再帰防止用 header `x-middleware-subrequest` を外から付けるだけで middleware 全体を
飛ばせた。認可を middleware に置いていた application は、その認可ごと飛ばされた。
Next.js 16 は middleware を `proxy.ts` に改名し、「認可の置き場所ではない」と
はっきりさせた。

ここから学ぶべき一般則は二つある。

1. **framework の制御信号を、利用者の入力と同じ channel に載せない。**
2. **認可は「通ったはずの層」ではなく、handler が受け取る値にする。**

**kofun-boot の形。** 認証済み主体を必要とする handler は、引数に `Principal` を取る。
`Principal` を構成できるのは、shell の認証段（capability を持つ adapter）だけである。
core は `Principal(` を構成できない。これは FCIS gate の
「core は capability を構成しない」と同じ grep で守る。

したがって、認証段を経由しない経路は **型が合わない**。
順序を差し替えても、header を偽造しても、無い引数は作れない。
dispatch の順序（size → route → method）は、既に gate が読んでいる。

**状態。** capability と FCIS gate は成立している。`Principal` は [#54](https://github.com/kofun-lang/kofun-boot/issues/54)。

## 4. Schema — Drizzle の場所に、Prisma の成果物を

**Prisma から取るもの。**

- schema が唯一の宣言であること
- 生成した migration SQL を repository に commit して review すること

**Drizzle から取るもの。**

- schema が host language の値であること（専用 DSL も codegen 段も要らない）
- 「SQL を知っていれば分かる」こと

**両方から捨てるもの。**

| 弱点 | Prisma | drizzle-kit | kofun-boot |
|---|---|---|---|
| rename の判定 | 名前の差分から drop+add を出し、data loss を警告する | rename か create かを対話で尋ねる | **column は key で同定する**。rename は label 変更なので推測しない |
| 削除した列の識別子 | 管理しない | 管理しない | key は **retired** になり、二度と発行しない（protobuf の `reserved`） |
| drift 検出 | shadow database に history を流す | snapshot JSON と比べる | history は **fold** である。build 時の関数呼び出しで、DB は要らない |
| 危険な step | 対話で確認する | 対話で確認する | **policy を書かないと apply が拒否する**。planner は policy を決して補わない |

**kofun-boot の形**（[ADR 8](../adr/0008-a-column-is-its-key.md)、
[ADR 9](../adr/0009-a-migration-history-is-a-fold.md)、[`DATA.md`](DATA.md)）:

```
apply  : Schema -> Migration -> SchemaStep     # 新しい schema と、起きたこと
replay : History -> Schema                     # shadow database = 関数呼び出し
drift  : Declared -> Replayed -> Drift         # InSync(live) | Diverged(key)
plan   : Current -> Desired -> Key -> Migration  # key で決め、policy は付けない
```

**gate**（`tests/schema/check.sh`、`tests/schema/postgres.sh`）。**今日成立している。**

- 次のことを binary の出力から名前付きで読む。
  - committed history の全 step が適用される
  - history が宣言どおりの schema に replay される
  - plan が空である
  - planner が history を **key ごとに再生成する**（rename は rename として出る）
  - 6 種類の拒否 probe がすべて schema を動かさない
- `contracts/schema.sql` と `contracts/migrations.sql` は投影である。手で編集すると落ちる。
- 実際の PostgreSQL 16 で、次の二つの DB の `pg_dump` が byte 単位で一致する。
  - migration SQL から作った DB
  - 宣言 DDL から作った DB
- NOT NULL を一つ外した DDL では一致しないことも確かめる。
- 壊した場合も名前付きで落ちることを、break test で示す。
  - 宣言だけの rename
  - 退役宣言の忘れ
  - history から policy を消す
  - planner が rename を drop にする
  - 手編集
  - 名前の無い列

## 5. Query と N+1 — 「自然な書き方」が batch になる

詳細は [`N_PLUS_ONE.md`](../research/N_PLUS_ONE.md) と
[ADR 10](../adr/0010-a-round-is-a-value.md)。

N+1 の原因は二つしかない。

1. **property access の裏の lazy loading**: Rails、Hibernate、EF Core の lazy proxy
2. **data が必要としない逐次化**: loop 内の await、monad の `>>=`

ORM の対策は、ほとんどが 1 への後付けの禁止である。

- Rails `strict_loading`
- SQLAlchemy `raiseload`
- Django 6.1 `FETCH_RAISE`
- Laravel `preventLazyLoading`

FP の対策（Haxl、Fetch、ZIO Query、Effect の `Request`）は 2 への答えである。
Applicative の `<*>` は独立な fetch を一 round にまとめる。

**kofun-boot は両方を構造で消す。**

- core は I/O できない。だから、裏で load する field は **存在しない**。
  strict mode という switch すら要らない。
- core は `Cmd`（不活性なデータ）を返す。shell はその round の全 fetch を、
  **実行前に値として見る**。そのため、次のことは関数一つで済む。
  - source ごとに一文へ合流する
  - 同じ key を一度だけ送る

  Applicative instance も、DataLoader の event-loop tick も要らない。
- row を map して一 round で要求する書き方が、最も自然な書き方であり、
  同時に batch になる。
- 入れ子の取得は宣言 shape にする。build 時に、一文の `LATERAL` + `json_agg`
  （Drizzle RQB、Prisma `relationLoadStrategy: "join"`、Hasura、PostgREST と同じ形）、
  または階層ごとの `IN` に compile する。

  兄弟 collection の直積爆発（EF Core と Hibernate が警告している）があるので、
  関係ごとに split を選べるようにする。

**Prisma 8 との違い。** Prisma 8 の ADR 003 は「一 query 一文」を強制する。
自動 batching は非決定的になるとして拒否している。
kofun-boot の合流は **round という値の純粋関数** である。tick にも scheduling にも
依存しないので、非決定性の問題がない。だから両方を持てる。

- 宣言 shape は一文にする
- 動的な round は合流させる

**gate**（`tests/loader/check.sh`）。**今日成立している。**

同じ request を N = 1, 2, 3, 4 で走らせ、出荷する strategy の文数が N で変わらないことを要求する。

| strategy | 文数 (N=1..4) | round 数 | 判定 |
|---|---|---|---|
| 一行ずつ逐次 await | 2 3 4 5 | N+1 | **N+1 として名指しで拒否** |
| 全行を一 round で要求 | 2 2 2 2 | 2 | 合格（round 数 = 依存の深さ） |
| 宣言 shape | 1 1 1 1 | 1 | 合格 |

Django の `assertNumQueries` は一つの fixture で数を固定する。
そのため、fixture が小さいあいだは per-row loader も通ってしまう。
この gate は **数が N に依存しないこと** を固定する。

次の三つを壊すと、どれも名指しで落ちる。

- application を逐次にする
- interpreter の合流を外す
- 重複 key の除去を外す

## 6. Cache — 推測された key を持たない

**Next.js から学ぶこと。** cache の既定値が三回変わった。

- Next 14: `fetch` を既定で cache していた
- Next 15: 既定を反転した
- Next 16: `cacheComponents` で opt-in の `"use cache"`、`cacheLife`、`cacheTag` になった

Vercel 自身も「Our Journey with Caching」で失敗を認めている。
それでも 2026-09-30 には次の advisory が出ている。

- 入れ子の `"use cache"` で root param の値をまたいで cache が漏れる（GHSA-h694-7cp9-m8p3）
- Draft Mode の内容が漏れる（GHSA-3w37-wq28-93x7）
- SSG/ISR の cache poisoning が二件

compiler が cache key を **推測** すると、入力を一つ見落としたときに漏洩になる。

**kofun-boot の形。**

- core の関数は純粋である。暗黙に読める cookie、header、param は無い。
  だから **関数の引数がそのまま入力のすべて** になる。key を引数から作れば、
  構成上欠けがない。
- 読み取りの cache は endpoint 値に **宣言** する。宣言するのは key、寿命、tag の三つ。
- 書き込みの `Cmd` は、自分が無効化する tag を宣言する。
- build 時に二つを検査する。
  - 読まれる tag には、無効化する書き込みか寿命のどちらかが必ずある
  - 宣言された cache は manifest に印字される

**状態。** [#56](https://github.com/kofun-lang/kofun-boot/issues/56)（設計のみ）。

## 7. 描画 — RSC の代わりに、view を ADT にする

React Server Components と PPR が解いている問題は二つある。

- 静的な殻を先に返すこと
- 動的な穴を後から流すこと

kofun-boot では [`TEA.md`](TEA.md) の決定により、`view : Model -> View` が閉じた
ADT を返す。

- 静的な殻は、build 時に `view(init)` を評価した値である。
- 動的な穴は `Sub` である。
- server-driven shell は、View の差分を流す。

「`"use client"` が module graph のどこで境界を引くか」という問題は起きない。
境界は shell の種類であって、ファイルの directive ではない。

**状態。** 決定済み（R10 #28 の判断待ちを含む）。実装は L9/L11。

## 8. Boot と設定 — Spring Boot の「Boot」を値で

Spring Boot 4 は auto-configuration を技術ごとの小さな module に分けた。
本当に価値があるのは container ではない。次の三つである。

- 依存に応じた既定値
- それを局所的に置き換えられること
- 何が適用されたかを説明する conditions report

**kofun-boot の形**（R2 [#17](https://github.com/kofun-lang/kofun-boot/issues/17)）。

- starter は **純粋な capability-pack 関数** である。発見される bean の集合ではない。
- 解決結果は、socket を開く前に完全な `ResolvedBoot` 値になる。
- 各 field は `value + source + reason` を持つ。
- `boot explain` が全行を印字する。上書きを一つすると、変わるのは一行だけである。
- capability manifest（既に成立）は、この報告の最初の section である。

## 9. Module と運用

- **Spring Modulith の `verify()`** は、kofun-boot では
  `scripts/check-modules.sh` が既に持っている。
  - module は contract/core/shell/tests を所有する
  - 他 module からは contract しか参照できない

  違反は、ファイルと行を名指しして落ちる。
- **Event Publication Registry**（業務 transaction の中に event を記録する）は、
  L12 の outbox として採る。delivery は at-least-once、consumer は idempotent で、
  replay を gate にする。
- **Actuator** の health と readiness は、route の横に手書きしない。
  runtime contract の投影にする（L2）。
- **Prisma 8 の `db sign`** は、DB の marker table に contract hash を書く。
  これは良い発想である。kofun-boot では次のようにする（[#51](https://github.com/kofun-lang/kofun-boot/issues/51)）。
  - DB が、自分の migrate された schema digest を持つ
  - binary は、起動時に自分の宣言 digest と比べて、違えば拒否する

## 10. Test — slice は annotation ではなく段

| 段 | 何を見るか | 道具 | 状態 |
|---|---|---|---|
| core | 純粋関数（業務ルール、合流、planner） | kotest、99 test、約 20 秒 | 成立 |
| seed | binary の出力を section ごとに名前付きで読む | `tests/*/check.sh` | 成立 |
| 投影 | 生成物が手で編集されていない | 同上 | 成立 |
| real socket | HTTP/1.1、keep-alive、SIGTERM drain | `tests/integration/serve.sh` | 成立 |
| real DB | 二つの SQL が同じ PostgreSQL を作る | `tests/schema/postgres.sh` | 成立 |
| replay | 記録した trace が byte 単位で再生される | `scripts/trace.sh` | 成立 |

Spring の Testcontainers（`@ServiceConnection`）が解くのは「本物の DB を test に配線する」問題である。
kofun-boot では DB は capability なので、配線は record の field を一つ変えるだけで済む。
本物の DB を使うのは、SQL 投影の検査と integration だけである。
業務ルールの test に DB は要らない。

## 11. CLI — 最初の一時間

| コマンド | 相当するもの | 状態 |
|---|---|---|
| `boot new` | `create-next-app`、Spring Initializr、`rails new` | 成立（生成物は毎 CI で自分の gate を通す） |
| `boot dev` | `next dev` | 成立（`--watch`） |
| `boot openapi` / `boot gen client` | — | 成立 |
| `boot db sql`（`dev.sh --schema`） | `prisma migrate diff`、`drizzle-kit generate` | 成立（投影の印字） |
| `boot db plan` / `boot db check` | `prisma migrate dev --create-only`、`drizzle-kit check` | [#57](https://github.com/kofun-lang/kofun-boot/issues/57) |
| `boot explain` | Spring の conditions report | R2 #17 |
| `boot mock` | json-server | #34 |

## 拒否するもの

- **reflection。** 例外なし。導出はすべて build 時に行う。
- **filesystem を route の真実にすること。** colocation は module で得る。
- **見えない endpoint。** Server Function も route table の行である。
- **middleware による認可。** 認可は構成できない値である。
- **推測された cache key。** key は引数から作る。
- **lazy loading と strict mode。** 存在しないものは禁止しなくてよい。
- **名前の差分による rename の推測と、対話による migration の確認。**
  CI に人はいない。
- **データ損失の既定値。** policy は人が書く。
- **測っていない数値。**

## 今回実装したもの

| module | 何を実証したか | gate |
|---|---|---|
| `modules/schema` | 次のことを、Stage 2 の固定 slot で両 backend・byte 一致で示した。<br>・key による同定<br>・退役 key<br>・fold としての history<br>・DB 無しの drift<br>・key による planner<br>・policy の強制 | `tests/schema/check.sh`、`tests/schema/postgres.sh` |
| `modules/loader` | 次のことを示した。<br>・round の合流（source ごとに一文、key は一度だけ）<br>・三つの strategy が同じ答えを返す<br>・N 非依存の文数<br>・N+1 の名指し | `tests/loader/check.sh` |

## 残りの道筋

今回実装した二つは [#45](https://github.com/kofun-lang/kofun-boot/issues/45) と [#46](https://github.com/kofun-lang/kofun-boot/issues/46) である。
続きは issue として登録し、[`ROADMAP.md`](../ROADMAP.md) にも並べた。

| issue | 内容 | lane |
|---|---|---|
| [#47](https://github.com/kofun-lang/kofun-boot/issues/47) | 複数 table と、key を名指す外部 key | L7 |
| [#48](https://github.com/kofun-lang/kofun-boot/issues/48) | 型変更の migration（拡大は可、縮小は `Discard` が必要） | L7 |
| [#49](https://github.com/kofun-lang/kofun-boot/issues/49) | 宣言 shape を `LATERAL` + `json_agg` か、階層ごとの `IN` に compile する | L7 |
| [#50](https://github.com/kofun-lang/kofun-boot/issues/50) | 型付き query 値と row codec、selection からの結果型（List/Text lowering 待ち） | L7 |
| [#51](https://github.com/kofun-lang/kofun-boot/issues/51) | DB が schema digest を持ち、binary が起動時に照合する | L7/L3 |
| [#52](https://github.com/kofun-lang/kofun-boot/issues/52) | release 済み history を追記専用にする（tag ごとに固定） | L7/L0 |
| [#53](https://github.com/kofun-lang/kofun-boot/issues/53) | data migration と backfill を `Cmd` 値にする | L7 |
| [#54](https://github.com/kofun-lang/kofun-boot/issues/54) | `Principal`: 認可は handler が受け取る値にする | L3 |
| [#55](https://github.com/kofun-lang/kofun-boot/issues/55) | 閉じた和から生成する wire codec。汎用 deserializer は持たない | L1 |
| [#56](https://github.com/kofun-lang/kofun-boot/issues/56) | 宣言 cache（key は引数から作る。寿命と tag を宣言する） | L2/L11 |
| [#57](https://github.com/kofun-lang/kofun-boot/issues/57) | `boot db plan / check / sql` | L8 |
| [#58](https://github.com/kofun-lang/kofun-boot/issues/58) | research pack に 2026-10 の文書を入れ、日付を更新する | R0/L10 |
