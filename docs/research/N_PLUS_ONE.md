# N+1 を起こさずに、快適に書く: 全手法の調査と kofun-boot の決定

調査日: 2026-10-04。

**出典の方針。** 各主張には一次資料を付けた。版と日付は、その日の npm・PyPI・GitHub
の release で確かめた。一部の公式サイト（prisma.io、hexdocs.pm、docs.djangoproject.com
など）には調査環境から直接届かなかった。そのため、同じ文書の GitHub 上の source を
読んだ場合があり、そのときは両方の URL を挙げる。検索結果の要約にしか頼れなかった
主張には **[要約のみ]** と付けた。

他人の benchmark の数値は他人の測定であり、kofun-boot の bar ではない。

## 結論

N+1 の原因は二つしかない。

1. **property access の裏で行われる lazy loading。** `user.posts` が field の読み出しに
   見えて、実際には query を発行する。
2. **data が必要としない逐次化。** loop の中で行ごとに await する。fetch 同士に依存は
   無いのに、コードの形が順番を強制する。monad の `>>=` も同じ形をしている。

既存の手法は、ほぼすべてがどちらか一方への答えである。

| 系統 | 対象 | 代表 | 保証 |
|---|---|---|---|
| eager loading API | 1 | Prisma `include`、Drizzle `with`、Rails `includes`、Django `prefetch_related`、SQLAlchemy `selectinload`、Ecto `preload`、EF Core `Include` | 書いた所だけ O(1) か O(深さ) |
| lazy の禁止 | 1 | Rails `strict_loading`、SQLAlchemy `raiseload`、Django 6.1 `FETCH_RAISE`、Laravel `preventLazyLoading`、Ecto `NotLoaded` | 実行時に例外になる |
| 自動の peer loading | 1 | Django 6.1 `FETCH_PEERS`、Laravel 12 `automaticallyEagerLoadRelationships`、Goldiloader | 1+N が 2 になる（mutable な identity 追跡が前提） |
| query compiler | 1 と 2 | Hasura、PostgREST、Drizzle RQB、Prisma `join`、jOOQ `MULTISET` | 入れ子の要求が一文になる |
| resolver batching | 2 | DataLoader、Absinthe Dataloader、java-dataloader | O(深さ × loader 数)。tick や dispatch に依存する |
| applicative batching（FP） | 2 | Haxl、Fetch、ZIO Query、Effect `Request` | O(依存の深さ) |
| 検出 | 両方 | Bullet、nplusone、Sentry、`assertNumQueries`、`SQLStatementCountValidator` | 実行時か、一つの fixture での数 |

**kofun-boot は両方の原因を構造で消し、残りを測定にする。**

- core は I/O できない。だから、裏で load する field は存在しない。原因 1 は無いので、
  禁止する switch も要らない。
- core は `Cmd` という不活性な値を返す。shell はその round の全 fetch を、実行前に値と
  して見る。だから「source ごとに一文、同じ key は一度だけ」に合流させる処理は、
  round の **純粋関数** になる。Haxl の Applicative も、DataLoader の tick も要らない。
- 行を map して一 round で要求するのが最も自然な書き方で、それがそのまま batch になる。
- 入れ子の読み出しは宣言 shape にする。build 時に、決まった文数（`LATERAL` +
  `json_agg` の一文、または階層ごとの `IN`）へ compile する。
- 一つの request の文数を N = 1..4 で測り、N で動く strategy を gate が名指しで拒否する。

実証は `modules/loader` と `tests/loader/check.sh`、決定は
[ADR 10](../adr/0010-a-round-is-a-value.md) と
[`docs/architecture/DATA.md`](../architecture/DATA.md) にある。

## A. ORM の eager loading API

### Prisma（v7 stable、v8 release candidate）

- **書くもの。** `include` か `select` に入れ子の relation を書く。
- **二つの戦略がある。** `relationLoadStrategy` で選ぶ。
  - `"join"`: database の中で解く。PostgreSQL では `LATERAL` join と JSON 集約、
    MySQL では相関 subquery を使い、一文になる。
  - `"query"`: table ごとに一文を発行し、application 側で結合する。
- **状態。** `relationJoins` preview flag として 5.7.0（2023-12）から存在する。
  v7 の文書でも、まだ Preview と書かれている **[要約のみ]**。
- **組み込みの dataloader。** 「同じ tick で、同じ `where` と `include` を持つ
  `findUnique()` を自動で batch する」。where がすべて同じ model の scalar field の
  場合に限られる。
- **失敗例。**
  - preview の feedback では、生成された lateral/JSON の SQL より素朴な `LEFT JOIN` の
    方が 2〜10 倍速かったという報告がある。
  - issue #23139 は PostgreSQL での性能退行の報告である。

**Prisma 8（TypeScript による書き直し、release candidate）の ADR 003 "One Query → One
Statement"** は kofun-boot に最も近い立場なので、詳しく見る。

- 一つの plan は、正確に一つの statement へ compile される。
- relation の走査は `LEFT JOIN LATERAL` + `json_agg(json_build_object(...))` になる。
- `includeMany` を使うには、contract の capability に `lateral` と `jsonAgg` が要る。
  無ければ compile 時のエラーになる。
- 自動 batching と透明な data loader は、非決定性と budget の複雑化を理由に **拒否**
  している。
- ADR 023 は、plan ごとの budget（行数、latency、SQL の長さ）を CI で評価する。

出典:
[relation queries](https://www.prisma.io/docs/orm/v7/prisma-client/queries/relation-queries)、
[query optimization](https://www.prisma.io/docs/orm/prisma-client/queries/query-optimization-performance)、
[feedback #22288](https://github.com/prisma/orm/discussions/22288)、
[#23139](https://github.com/prisma/prisma/issues/23139)、
[ADR 003](https://github.com/prisma/orm/blob/main/docs/architecture%20docs/adrs/ADR%20003%20-%20One%20Query%20One%20Statement.md)、
[ADR 023](https://github.com/prisma/orm/blob/main/docs/architecture%20docs/adrs/ADR%20023%20-%20Budget%20Evaluation.md)

### Drizzle

- **書くもの。** `db.query.users.findMany({ with: { posts: true } })`。
- **公式の主張。** 「Drizzle always outputs exactly one SQL query」。lateral join と
  JSON 集約で実現している。
- **Relational Queries v2。**
  - 2025-03-13 に merge された（PR #3974）。
  - `defineRelations()` 一つで全 table を宣言する。
  - relation filter と、入れ子の `where`・`orderBy` を持つ。
- **版。** npm の stable は 0.45.3（2026-09-21）、`rc` は 1.0.0-rc.4。1.0 はまだ stable
  ではない。
- **失敗例。** 第三者の benchmark では、規模が大きいと一文が速く、小さい結果では
  分割 query とほぼ同じだった。一文が常に最適とは限らない。

出典:
[rqb](https://orm.drizzle.team/docs/rqb)、
[data-querying source](https://github.com/drizzle-team/drizzle-orm-docs/blob/main/src/content/docs/data-querying.mdx)、
[PR #3974](https://github.com/drizzle-team/drizzle-orm/pull/3974)、
[benchmark](https://github.com/webNeat/sql-single-vs-multiple-queries)

### Rails Active Record（と Laravel）

- **三つの eager loading。**
  - `preload`: association ごとに一文。
  - `eager_load`: `LEFT OUTER JOIN` で一文。
  - `includes`: 通常は `preload` と同じだが、association に条件があると JOIN になる。
- **`strict_loading`。**
  - relation、record、association の単位で付けられる。
  - lazy load すると `StrictLoadingViolationError` が発生する。
  - `mode: :n_plus_one_only` にすると、N+1 になる lazy load だけを拒否する。
  - 既定値（`strict_loading_by_default`）は `false` である。
- **周辺の gem。**
  - Bullet は request を囲んで、N+1 と不要な eager load を検出する。
  - Goldiloader は、最初に走査したとき、同じ集合の全 model に対して自動で eager load
    する。
- **Laravel。**
  - `Model::preventLazyLoading()` で lazy load を禁止できる。
  - 12.x には `automaticallyEagerLoadRelationships()` がある。

出典:
[guide](https://guides.rubyonrails.org/active_record_querying.html#eager-loading-associations)、
[Bullet](https://github.com/flyerhzm/bullet)、
[Goldiloader](https://github.com/salsify/goldiloader)、
[Laravel](https://laravel.com/docs/12.x/eloquent-relationships#preventing-lazy-loading)

### Django

- **二つの基本 API。**
  - `select_related`: FK と 1:1 を同じ query で JOIN する。
  - `prefetch_related`: relation ごとに追加の batch query を一つ発行し、Python 側で
    結合する。`Prefetch` object で queryset を調整できる。
- **Django 6.1（2026-08-05）の fetch mode。** `QuerySet.fetch_mode()` で選ぶ。
  - `FETCH_ONE`: 既定値。1+N になる。
  - `FETCH_PEERS`: 欠けている field を、同じ QuerySet の全 instance について一度に
    取る。多くの N+1 を 2 query にする。
  - `FETCH_RAISE`: `FieldFetchBlocked` を発生させる。
  - 制約: 逆 FK や M2M の manager には効かない。
- **検出。** 組み込みは test 用の `assertNumQueries` だけである。第三者製に
  `nplusone` と `django-zen-queries` がある。

出典:
[fetch modes](https://docs.djangoproject.com/en/6.1/topics/db/fetch-modes/)、
[6.1 release notes](https://github.com/django/django/blob/main/docs/releases/6.1.txt)、
[nplusone](https://github.com/jmcarp/nplusone)、
[zen-queries](https://github.com/dabapps/django-zen-queries)

### SQLAlchemy 2.x

- **loading 戦略。**
  - `selectinload`: 親の主キーを `IN` に入れた二文目を出す。一文あたり最大 500 key。
  - `joinedload`、`subqueryload`。
  - `raiseload`（`lazy="raise"`）: lazy load を禁止する。`raise_on_sql` にすると、SQL を
    出す lazy load だけを禁止する。
- **公式の推奨。** collection には `selectinload`、many-to-one には `joinedload`。
- **asyncio。** 「暗黙の I/O は許されない」。`AsyncAttrs` か `lazy="raise"` を使う。

出典:
[relationship loading](https://docs.sqlalchemy.org/en/20/orm/queryguide/relationships.html)、
[asyncio](https://docs.sqlalchemy.org/en/20/orm/extensions/asyncio.html#preventing-implicit-io-when-using-asyncsession)

### Hibernate / JPA / Spring Data

- **Hibernate 7.1 の Introduction の立場。**
  - N+1 は「Hibernate のバグでも制限でもない。解決できるのは開発者だけ」。
  - 「ほぼ常に outer join fetching を使え」。
  - batch fetching（`@BatchSize`、`default_batch_fetch_size`）は問題を **緩和** するが、
    解決はしない。
  - JPA の `@ManyToOne` が既定で eager なのは「不幸な misfeature」である。
  - 兄弟 collection を join すると直積になる。その場合は subselect fetching を使う。
- **Spring Data JPA。** `@EntityGraph` で method ごとに fetch plan を決める。
- **Spring Data JDBC。** 設計上「lazy loading も cache も無い」。aggregate 全体を load
  する。Single Query Loading（3.2〜、experimental）は aggregate を一文で load するが、
  制約が多く、満たさないと黙って fallback する。

出典:
[Hibernate 7.1 Introduction](https://docs.hibernate.org/orm/7.1/introduction/html_single/Hibernate_Introduction.html)、
[Spring Data JDBC](https://docs.spring.io/spring-data/relational/reference/jdbc/entity-persistence.html)

### Ecto（Elixir）

- **lazy loading が無い。** load していない association は
  `%Ecto.Association.NotLoaded{}` という struct になる。
- **preload。** association ごとに、全親分をまとめた別 query を一つ発行する。
  transaction の外では並列に走る。
- **join preload。** 一文で済むが、親の行が重複する。公式は「既に main query で join
  しているときだけ join を使え」と勧める。

出典: [preload/3](https://hexdocs.pm/ecto/Ecto.Query.html#preload/3)

### EF Core

- **既定。** `Include` は JOIN の一文になる。
- **直積爆発。** 兄弟 collection を同時に include すると行数が掛け算になる。
  例: 10 posts × 10 contributors で、blog 一件あたり 100 行。
- **`AsSplitQuery()`。** collection ごとに一文に分ける。その代わり次の代償がある。
  - 文と文の間の一貫性が無い。
  - round trip が増える。
  - buffering が要る。
- **lazy loading proxy。** opt-in であり、公式文書も「余計な round trip を生みやすい」
  と書いている。

出典: [single vs split](https://learn.microsoft.com/en-us/ef/core/querying/single-split-queries)

### jOOQ、Kysely、Exposed

- **jOOQ の `MULTISET`（3.15〜）。** 標準 SQL の値構成子で、相関 subquery を
  collection として入れ子にする。対応していない方言では SQL/JSON や XML で emulate
  する。
- **jOOQ 自身の benchmark（2022-06-09、PostgreSQL）[要約のみ]。**

  | 方式 | 相対 throughput |
  |---|---|
  | join + client 側の重複除去 | 4413 |
  | `MULTISET` JSONB | 2739 |
  | 二 query | 2256 |
  | N+1 | 265 |

  N+1 以外は同じ桁にあり、N+1 だけが一桁遅い。
- **Kysely。** `jsonArrayFrom` で `json_agg` subquery を手で書く。
- **Exposed。** `.with()` で一文の eager load をする。

出典:
[MULTISET](https://blog.jooq.org/jooq-3-15s-new-multiset-operator-will-change-how-you-think-about-sql/)、
[benchmark](https://blog.jooq.org/the-performance-of-various-to-many-nesting-algorithms/)、
[Kysely relations](https://kysely.dev/docs/recipes/relations)

## B. 入れ子の要求を一文に compile する

- **Hasura。** GraphQL を一つの SQL に compile し、認可規則も push-down する。
  直積を返す join ではなく、DB 内の JSON 集約を使う。remote schema に対しては
  DataLoader 型の batching に戻る。
- **PostgREST。** resource embedding は、FK から関係を見つけて、一回の API 呼び出しで
  返す。生成される SQL は `LEFT JOIN LATERAL (SELECT json_agg(...))` である（PR #1949）。
- **PostGraphile V5 / Grafast（2026-03-24）。**
  - resolver を plan resolver に置き換えた。
  - 操作全体を plan してから実行する。
  - 各 step が全値を一度の `execute()` で batch 処理する。
  - 文数は data ではなく plan で決まる。「一文」という主張は見つからなかった。

出典:
[Hasura architecture](https://hasura.io/blog/architecture-of-a-high-performance-graphql-to-sql-engine-a9ad5e5b0d84)、
[PostgREST PR #1949](https://github.com/PostgREST/postgrest/pull/1949)、
[Grafast](https://grafast.org/grafast/)、
[V5](https://postgraphile.org/news/2026-03-24-v5-published/)

## C. resolver 層の batching と cache

- **DataLoader。**
  - 同じ event-loop tick で起きた load をまとめる。
  - batch 関数の契約: 返す値の配列は key の配列と同じ長さ、同じ順序でなければならない。
  - cache は request ごとの memoization である。
  - 弱点:
    - 要素ごとに Promise を一つ作る。
    - batch の範囲が scheduling で決まる。
- **Absinthe Dataloader。** `load` で積み、`run` で取る二段構えである。
- **java-dataloader。** `dispatch()` を呼び忘れると future が永遠に完了しない。
  batch の窓と latency の取引が API に露出している。

出典:
[dataloader](https://github.com/graphql/dataloader)、
[absinthe dataloader](https://github.com/absinthe-graphql/dataloader)、
[java-dataloader](https://github.com/graphql-java/java-dataloader)

## D. 関数型の手法

### Haxl（Facebook、Haskell）

Marlow、Brandy、Coens、Purdy の論文
"There is no Fork: an Abstraction for Efficient, Concurrent, and Concise Data Access"
（ICFP 2014）が出発点である。

- **仕組み（source で確認した）。**
  - 計算の一歩は `Done`、`Throw`、`Blocked` のどれかを返す。
  - `<*>` は、左が `Blocked` でも右を走らせる。両方の fetch が一つの batch に集まる。
  - `>>=` は左の結果を待つしかないので、data 依存が直列になる。
  - したがって round 数は、monad 的依存の最長の鎖の長さになり、N に依存しない。
- **周辺の仕組み。**
  - request ごとの cache が重複を除き、一貫性を保つ。
  - `dumpCacheAsHaskell` は cache の内容を Haskell の code として出力する。これで
    test 用に request を再生できる。
  - Haxl 2 は厳密な round をやめ、依存が満たされた断片から再開する方式に変わった。
- **ApplicativeDo。**
  - GHC の拡張で、依存の無い `do` を `<*>` に脱糖し、並列性を引き出す。
  - Marlow、Peyton Jones、Kmett、Mokhov の論文（Haskell Symposium 2016）がある。
- **実績。** Facebook の spam 対策 engine である Sigma が Haxl で書き直された
  **[要約のみ]**。

出典:
[paper](https://simonmar.github.io/bib/papers/haxl-icfp14.pdf)、
[Haxl](https://github.com/facebook/Haxl)、
[Monad.hs](https://github.com/facebook/Haxl/blob/main/Haxl/Core/Monad.hs)、
[ApplicativeDo](https://ghc.gitlab.haskell.org/ghc/doc/users_guide/exts/applicative_do.html)、
[Sigma](https://engineering.fb.com/2015/06/26/security/fighting-spam-with-haskell/)

### Fetch（Scala）、ZIO Query、Effect、Stitch、muse/Urania

- **Fetch。**
  - cats-effect の上にある Haxl 移植である。
  - applicative 積は batch になり、`flatMap` は「二 round」になる。
  - `traverse` は自動で batch になる。
- **ZIO Query。**
  - `zipWithPar` で並べた request は batch に、`zipWith` で並べた request は pipeline
    になる。
  - 重複除去と cache がある。
  - `ZQuery.foreachPar(ids)(getUserNameById)` は N+1 ではなく 2 query になる。
- **Effect（4.0.0 が 2026-10-01 に stable になった）。**
  - request は `Request.tagged` で作るデータで、`RequestResolver` が batch を解く。
  - `Effect.forEach(xs, f, { batching: true })` と書く。
  - 公式の例: N+1 なら 1+2n query になるところが、「n に関係なく 3 query」になる。
  - v4 では、resolver に batch を待つ遅延の窓があり、DataLoader に近づいた。
- **Stitch（Twitter）。** 非公開で、一次資料は講演だけである。
- **muse / Urania（Clojure）。** Haxl と Stitch を手本にしている。

出典:
[Fetch](https://github.com/xebia-functional/fetch)、
[ZIO Query](https://zio.dev/zio-query/)、
[Effect batching](https://effect.website/docs/batching/)、
[Effect v4 batching](https://github.com/Effect-TS/website/blob/main/apps/web/src/content/docs/v4/batching.mdx)、
[muse](https://github.com/kachayev/muse)、
[Urania](https://github.com/funcool/urania)

### 理論: なぜ applicative は見え、monad は見えないか

- **Capriotti と Kaposi、"Free Applicative Functors"（MSFP 2014）。** 計算の構造が
  事前に決まっているときは applicative を使え。そうすれば静的解析ができる。
- **Mokhov、Mitchell、Peyton Jones、"Build Systems à la Carte"（ICFP 2018）。**
  - applicative な task の依存は、code を見れば分かる。
  - monad 的な task の依存は、走らせないと分からない。
- **"Selective Applicative Functors"（ICFP 2019）。** 静的な宣言と動的な選択の中間を
  扱う。Haxl が事例研究になっている。
- **Gill ら、"The Remote Monad Design Pattern"（Haskell 2015）。** 遠隔命令の
  まとめ方を weak、strong、applicative の三段階で比べている。
- **Cheney、Lindley、Wadler、"Query shredding"（SIGMOD 2014）。** 入れ子の query は、
  data ではなく **結果型の入れ子の深さ** で決まる数の SQL になる。

出典:
[arXiv 1403.0749](https://arxiv.org/abs/1403.0749)、
[Build Systems à la Carte](https://www.microsoft.com/en-us/research/uploads/prod/2018/03/build-systems-a-la-carte.pdf)、
[Selective](https://doi.org/10.1145/3341694)、
[Remote Monad](https://ku-fpg.github.io/files/Gill-15-RemoteMonad.pdf)、
[Query shredding](https://arxiv.org/abs/1404.7078)

### Datomic pull と elm-graphql

- **Datomic の pull pattern。** 入れ子の選択をデータとして宣言する。
- **dillonkearns/elm-graphql。** kofun-boot に最も近い。
  - `SelectionSet` は、静的な field の list と、純粋な decoder の組である。
  - `map` と `map2..8` はあるが、**`andThen` が無い**。
  - だから query 全体が送信前に決まり、一つの `SelectionSet` が一つの HTTP request に
    なる。
  - その request を `Cmd msg` という不活性なデータで返す。

出典:
[Datomic pull](https://docs.datomic.com/query/query-pull.html)、
[SelectionSet.elm](https://github.com/dillonkearns/elm-graphql/blob/master/src/Graphql/SelectionSet.elm)

## E. 検出と強制

- **アクセス時に拒否する。**
  - Rails `strict_loading`
  - SQLAlchemy `raiseload`
  - Django 6.1 `FETCH_RAISE`
  - Laravel `preventLazyLoading`
  - Ecto `NotLoaded`（構成上そうなる）
- **実行時 profiler。**
  - Bullet と nplusone は request を観察する。
  - Sentry は「似た記述の、重ならない DB span が逐次に並ぶ」ことで検出する。
    条件は合計 50ms 超、約 5 span 超などである。
- **test 時の文数 assertion。**
  - Django `assertNumQueries`
  - Hibernate `Statistics`
  - hypersistence-utils の `SQLStatementCountValidator`
- **plan 時の検査。** Prisma 8 の「一 plan 一文」と budget。

出典:
[Sentry](https://docs.sentry.io/product/issues/issue-details/performance-issues/n-one-queries/)、
[hypersistence-utils](https://github.com/vladmihalcea/hypersistence-utils)

## F. 一文、分割、N+1 の測定から言えること

| 出典 | 結果 |
|---|---|
| jOOQ benchmark | join、`MULTISET`、二 query は同じ桁で、N+1 だけが一桁遅い |
| Drizzle の第三者 benchmark | 規模が大きいと一文が勝つが、小さい結果では差が無い |
| Prisma の feedback | lateral/JSON が素朴な join より遅い報告がある |
| EF Core、Hibernate | 兄弟 collection の join は直積爆発する |

したがって設計上の結論は、**一文が常に正解なのではない** ということである。
正解は **文数が N に依存しないこと** であり、関係ごとに一文か分割かを選べることである。

## kofun-boot の決定

1. **lazy field は存在しない。** core は I/O できず、row は record である。
   strict mode は要らない。
2. **round は値である。** core は今要求できるものを、一つの `Cmd` にすべて入れる。
   interpreter は実行の前に `coalesce : Round -> Batch` で合流させる。
   - source ごとに一文、同じ key は一度だけ送る。
   - batch は round の純粋関数なので、trace と同じく決定的である。
   - そのため、Prisma 8 が自動 batching を拒否した理由（非決定性）が当てはまらない。
3. **自然な書き方が batch になる。** update が受け取った行を map して要求を作る。
   これが最も短い書き方で、そのまま一 round になる。
   N+1 を書く方法は「答えを一つずつ待つ」ことだけである。それは可視であり、gate が拒否する。
4. **round 数は依存の深さで決まる。** 前の答えが要る fetch だけが次の round に回る。
   これは Haxl の保証と同じで、それを `Cmd`/`Msg` の往復として目に見える形にしたものである。
5. **入れ子は宣言 shape にする。**
   - build 時に、`LATERAL` + `json_agg` の一文か、階層ごとの `IN` に compile する。
   - 方言に機能が無ければ build error にする（Prisma 8 の capability gate と同じ）。
   - 兄弟 collection は関係ごとに分割を選べる。
6. **結果型は selection から導出する**（Drizzle、Prisma、elm-graphql と同じ）。
   選んでいない relation は型に無いので、実行時の `NotLoaded` すら要らない。
   List/Text lowering 待ちである（[#50](https://github.com/kofun-lang/kofun-boot/issues/50)）。
7. **N+1 は N に対して測る。** trace が全 round を記録する。同じ request を
   N = 1..4 で走らせ、出荷する strategy の文数が動いたら名指しで落とす。
   逐次の strategy を出力に残し、検出器が毎回発火することを示す。

## 実装済みのもの（2026-10-04）

`modules/loader` が、著者ごとの投稿数を取る一つの request を三通りに書いている。
`tests/loader/check.sh` が binary の出力を読む。

| strategy | 文数 N=1..4 | round 数 | 答え |
|---|---|---|---|
| 一行ずつ逐次 | 2 3 4 5 | N+1 | 3 4 8 9 |
| 一 round で全行 | 2 2 2 2 | 2 | 3 4 8 9 |
| 宣言 shape | 1 1 1 1 | 1 | 3 4 8 9 |

次の三つを壊すと、どれも名指しで落ちる。

- application を逐次にする
- interpreter の合流を外す
- 重複 key の除去を外す

**実際の PostgreSQL でも測った。** 宣言 shape は build 時に SQL へ compile する
（`contracts/shapes.sql`）。

- join: `LEFT JOIN LATERAL` + `json_agg` の一文
- split: 階層ごとの文

`tests/loader/postgres.sh` は、使い捨ての cluster を `log_statement = 'all'` で
起動する。文数は、この script ではなく **server 自身のログ** から数える。

| 書き方 | server が数えた文数 N=1..4 |
|---|---|
| join shape | 1 1 1 1 |
| split shape | 2 2 2 2 |
| 一行ずつ（対照） | 2 3 4 5 |

三つとも、N ごとに seed と同じ答えを返す。`LATERAL` の無い方言（SQLite）では、
join は relation を名指しして build 時に拒否される。

続きは issue にした。

- 複数 relation の shape と、relation ごとの分割の選択: [#49](https://github.com/kofun-lang/kofun-boot/issues/49) の続き
- 型付き query 値: [#50](https://github.com/kofun-lang/kofun-boot/issues/50)

今回の実装は [#46](https://github.com/kofun-lang/kofun-boot/issues/46) である。
