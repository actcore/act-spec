# Универсальный стандарт компонентов через wasip3 и MCP

**Created:** 3/5/2026 0:00:20  
**Updated:** 3/5/2026 1:12:24  
**Exported:** 3/5/2026 12:41:08  
**Link:** [https://claude.ai/chat/c57ec5dc-42b8-40d3-872b-391c01071ae9](https://claude.ai/chat/c57ec5dc-42b8-40d3-872b-391c01071ae9)  

## Prompt:
3/5/2026, 12:00:21 AM

Я хочу сделать стандарт для компонентов, которые смогут применять и агенты, и разработчики приложений. То есть, чтобы агент мог вызывать функции через MCP-подобный интерфейс, а разработчик приложений через некоторый бинарный протокол. Я рассматриваю для этого спецификацию wasip3 с определённым API для wasi-компонентов, и mcp-переходник, который сможет запускать такие компоненты через wasm runtime, доставать из них информацию о функциях и так далее .



## Response:
3/5/2026, 12:00:44 AM

Интересная архитектура! Ты по сути описываешь **универсальный компонентный стандарт** с двумя слоями доступа:

```
┌─────────────────────────────────────────────┐
│           WASI Component (.wasm)            │
│         (бизнес-логика, инструменты)        │
└──────────────┬──────────────────────────────┘
               │  WIT interface (wasip3)
       ┌───────┴────────┐
       │                │
┌──────▼──────┐  ┌──────▼──────────┐
│ MCP Adapter │  │  Binary Protocol│
│ (агенты/LLM)│  │  (приложения)   │
└─────────────┘  └─────────────────┘
```

Это очень логичная идея, и wasip3 + WIT действительно подходит как основа. Давай разберу ключевые точки.

---

## Что даёт wasip3 / WIT здесь

**WIT (WebAssembly Interface Types)** — это и есть твой "контракт":

```wit
// tools.wit
package myorg:tools;

interface tool-provider {
  record tool-definition {
    name: string,
    description: string,
    input-schema: string,  // JSON Schema
  }

  record tool-call {
    name: string,
    arguments: string,  // JSON
  }

  record tool-result {
    content: string,
    is-error: bool,
  }

  list-tools: func() -> list<tool-definition>;
  call-tool: func(call: tool-call) -> result<tool-result, string>;
}

world tools-world {
  export tool-provider;
}
```

Компонент экспортирует этот интерфейс — и оба адаптера умеют с ним работать.

---

## MCP-адаптер

Здесь логика простая: wasmer/wasmtime запускает компонент, вызывает `list-tools`, получает схемы, и проксирует их как MCP tools:

```
wasm component → list-tools() → MCP tools/list response
wasm component → call-tool()  → MCP tools/call response
```

Плюс wasip3 даёт **async через WASI async** — что важно для MCP, который работает поверх stdio/SSE.

---

## Ключевые вопросы, которые стоит проработать

**1. Sandboxing и capabilities**
wasip3 даёт возможность явно разрешать компоненту доступ к сети, FS и т.д. через линковку хостовых импортов. Это важно для безопасности агентских инструментов.

**2. Async модель**
wasip3 вводит `wasi:io` с pollable/streams — нужно решить, как MCP-адаптер управляет event loop компонента.

**3. Composition**
WIT Component Model позволяет **компоновать компоненты** — несколько `.wasm` файлов можно слинковать в один. Это открывает возможность "пакетов инструментов".

**4. Бинарный протокол для приложений**
Что рассматриваешь? Cap'n Proto / flatbuffers поверх Unix socket? Или что-то вроде gRPC с proto-схемой, генерируемой из WIT?

---

Есть несколько проектов в этом направлении для ориентира: **WASI Cloud** от Fermyon, **Extism** (плагины поверх wasm с PDK), **wasmCloud** (акторная модель). Но именно связки "WIT-компонент как MCP tool provider" я не видел — это оригинальная ниша.

С чего хочешь начать — со спецификации WIT интерфейса, или с прототипа MCP-адаптера на Rust?



## Prompt:
3/5/2026, 12:10:07 AM

1. Хороший вопрос для проработки
2. MCP-адаптер должен взять на себя создание event loop. Если внутри компонента нужно создавать корутины, то это должно обрабатываться либо стандартными средствами wasip3 (если есть spawn), либо самим компонентом (разработчик может принести асинхронный рантайм внутрь компонента)
3. Отлично
4. Компонент должен общаться с mcp/бинарной прослойкой через вызовы wasi. А агент с mcp посредством стандартного mcp-совместимого интерфейса. Нужно помнить, что компонент — long running и stateful.



## Response:
3/5/2026, 12:10:34 AM

Отличные уточнения. Давай переосмыслю архитектуру с учётом stateful + long-running компонента.

---

## Пересмотренная архитектура

```
┌─────────────────────────────────────────────────────┐
│                  MCP Adapter (Rust)                 │
│                                                     │
│  ┌─────────────┐    ┌──────────────────────────┐   │
│  │  MCP Server │    │   Component Host         │   │
│  │  (stdio/SSE)│◄──►│   (wasmtime)             │   │
│  └─────────────┘    │                          │   │
│                     │  ┌────────────────────┐  │   │
│                     │  │  WASM Component    │  │   │
│                     │  │  (long-running,    │  │   │
│                     │  │   stateful)        │  │   │
│                     │  └────────────────────┘  │   │
│                     │   event loop owned here  │   │
│                     └──────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

Компонент **не завершается** между вызовами — это принципиально меняет модель по сравнению с типичным serverless wasm.

---

## Проблема: stateful компонент и WIT

Стандартный WIT экспорт — это stateless вызов функции. Для stateful нужно либо:

**Вариант A: Resource handles**
```wit
interface tool-provider {
  resource session {
    constructor();
    list-tools: func() -> list<tool-definition>;
    call-tool: func(call: tool-call) -> result<tool-result, string>;
  }
}
```
Компонент держит состояние внутри `session` объекта. Хост держит handle живым.

**Вариант B: Implicit state**
Компонент — один синглтон, состояние глобальное внутри него. Проще, но нет изоляции между сессиями.

**Вариант C: Multiple component instances**
Wasmtime поддерживает несколько инстансов одного компонента. Каждая MCP-сессия = отдельный инстанс.

Вариант A выглядит наиболее чистым для Component Model.

---

## Async: кто владеет event loop

```
MCP Adapter (Rust, tokio)
    │
    ├── wasmtime::component::Call  ← синхронный или async вызов в компонент
    │
    └── Component внутри:
            ├── может использовать wasi:io/poll для I/O
            ├── может иметь внутренний async runtime (например, wstd)
            └── НЕ может спавнить OS-треды
```

Ключевой момент: **wasip3 async** (WASI Preview 3) вводит `async`-функции в WIT через `future` и `stream` типы:

```wit
interface tool-provider {
  resource session {
    call-tool: async func(call: tool-call) -> result<tool-result, string>;
    // возвращает future, которую хост дривит через свой event loop
  }
}
```

Хост (tokio) дривит `future` из компонента — компонент может внутри делать `wasi:io` операции, которые интегрируются в тот же poll loop. Это именно то, что описывает wasip3.

---

## Бинарный протокол для приложений

Раз компонент общается через WASI вызовы, бинарная прослойка выглядит так:

```
Application (любой язык)
    │
    │  Unix socket / pipe (бинарный протокол)
    │
    ▼
Binary Adapter (Rust)  ←── тот же Component Host
    │
    │  WIT calls
    ▼
WASM Component
```

Для протокола хорошо подходит **Cap'n Proto** — он умеет генерировать биндинги из схемы, и схема может генерироваться из WIT автоматически. Либо более простой вариант — **length-prefixed protobuf/msgpack** если не нужна zero-copy.

---

## Главный открытый вопрос

**wasip3 как спецификация ещё не финализирован.** Async WIT (`future`/`stream`) есть в wasmtime как экспериментальная фича (`--wasm component-model-async`). Это значит:

- Можно прототипировать уже сейчас на wasmtime nightly
- Но спека может измениться до стабилизации

Ты готов работать с экспериментальным API, или нужна более стабильная основа (wasip2 + ручной async через callbacks/poll)?



## Prompt:
3/5/2026, 12:21:42 AM

Stateful: 1 отличный вариант.
Async: треды же можно сравнить в wasi при необходимости.
Протокол: для бинарных адаптеров могут быть разные use-case. Я считаю, что нужно сделать одну референсную реализацию, которая линкуется в приложение и может запускать компоненты. Плюс, консольную утилиту, вызывающую tools. Плюс, возможно, сервер, который хостит приложения и отдаёт их по API через некоторый rpc-формат (типа cbor/json). Последний можно объединить с mcp-сервером, потому что функционально они похожи.
Экспериментальный статус: да, готов



## Response:
3/5/2026, 12:22:08 AM

Отлично, картина становится чёткой. Давай зафиксирую итоговую архитектуру.

---

## Компоненты системы

```
┌─────────────────────────────────────────────────────────────┐
│                    WIT Specification                        │
│              (tool-provider, session resource)              │
└──────────┬──────────────────────────────────────────────────┘
           │  реализуют компоненты (.wasm)
           │
     ┌─────┴──────────────────────────────────────┐
     │           Component Host (Rust lib)         │
     │   - wasmtime embedding                      │
     │   - управление инстансами/сессиями          │
     │   - event loop (tokio)                      │
     └─────┬──────────────────┬────────────────────┘
           │                  │
    ┌──────▼──────┐    ┌──────▼──────────────────────┐
    │  CLI tool   │    │   Server (MCP + RPC unified) │
    │  (invoke    │    │   - MCP over stdio/SSE        │
    │   tools)    │    │   - CBOR/JSON API             │
    └─────────────┘    └──────────────────────────────┘
```

---

## Component Host — ядро системы

Это Rust-библиотека, которую линкуют все остальные:

```rust
// Публичный API библиотеки
pub struct ComponentHost {
    engine: wasmtime::Engine,
    // пул инстансов per component path
}

pub struct Session {
    // держит wasmtime Store + handle на resource session
    // long-running, не дропается между вызовами
}

impl ComponentHost {
    pub async fn load(&self, path: &Path) -> Result<ComponentHandle>;
}

impl ComponentHandle {
    pub async fn new_session(&self) -> Result<Session>;
}

impl Session {
    pub async fn list_tools(&mut self) -> Result<Vec<ToolDefinition>>;
    pub async fn call_tool(&mut self, name: &str, args: Value) -> Result<ToolResult>;
}
```

---

## Треды в WASI

Ты прав — `wasi:threads` существует (Preview 2), и wasmtime его поддерживает. Модель такая:

```
Component Host (tokio)
    │
    └── wasmtime instance
            ├── main "thread" ← async WIT calls сюда
            └── wasi:threads spawn → OS threads через хост
                    (хост предоставляет thread pool)
```

Важный нюанс: `wasi:threads` требует **shared memory** (`shared` linear memory в компоненте). Это значит компонент должен быть скомпилирован с `--target wasm32-wasip1-threads` или аналогом. Для Component Model + threads сейчас есть трения — спека в процессе. Но для большинства случаев async WIT futures + внутренний single-threaded runtime в компоненте (типа `tokio` в wasm) достаточно.

---

## Unified Server: MCP + RPC

Раз функционально похожи — один сервер, два транспорта:

```
┌────────────────────────────────────────┐
│           Unified Server               │
│                                        │
│  ┌─────────────┐   ┌────────────────┐  │
│  │  MCP layer  │   │   RPC layer    │  │
│  │  stdio/SSE  │   │  HTTP+CBOR     │  │
│  └──────┬──────┘   └───────┬────────┘  │
│         └─────────┬─────────┘          │
│              ┌────▼────┐               │
│              │ Router  │               │
│              └────┬────┘               │
│         Component Host (lib)           │
└────────────────────────────────────────┘
```

MCP `tools/call` и RPC `POST /invoke` — оба транслируются в `session.call_tool()`.

---

## Структура репозитория

```
wasm-tool-platform/
├── crates/
│   ├── wit/                  # WIT спецификация
│   │   └── tool-provider.wit
│   ├── host/                 # Component Host (lib)
│   ├── cli/                  # CLI утилита
│   └── server/               # Unified MCP+RPC сервер
├── sdk/
│   ├── rust/                 # Guest SDK (макросы, биндинги)
│   └── python/               # Guest SDK для Python (via componentize-py)
└── examples/
    └── hello-tool/           # Пример компонента
```

---

## Следующий шаг

Я бы предложил начать с **WIT спецификации + минимального host** с одним синхронным инструментом — чтобы проверить что wasmtime поднимает компонент и вызывает `list-tools`. Потом наращивать async и сессии.

Начнём писать WIT и scaffold host-крейта?



## Prompt:
3/5/2026, 12:24:23 AM

Мы пока проектируем. Как сделать так, чтобы новый стандарт мог в будущем заменить mcp в техническом плане?



## Response:
3/5/2026, 12:24:55 AM

Хороший стратегический вопрос. Давай разберём что такое MCP технически и где наш стандарт может его превзойти.

---

## Что такое MCP технически

MCP — это по сути три вещи:

1. **Транспорт** — stdio, SSE, (скоро) streamable HTTP
2. **Протокол** — JSON-RPC 2.0
3. **Абстракции** — tools, resources, prompts, sampling

Слабые места MCP:
- **Нет типизации** — схемы инструментов это JSON Schema строки, никакой статической проверки
- **Нет стейта** — каждый вызов stateless, сессионность самодельная
- **Нет изоляции** — сервер это просто процесс, sandbox на совести автора
- **Нет композиции** — нельзя скомпоновать несколько серверов в один компонент
- **Транспорт жёстко связан** с форматом

---

## Как наш стандарт закрывает эти проблемы

```
MCP проблема          → Наше решение
─────────────────────────────────────────────────────
Нет типизации         → WIT — строго типизированный IDL
Нет стейта            → session resource, long-running instance
Нет изоляции          → wasm sandbox + capability-based security
Нет композиции        → Component Model linking
Транспорт ≡ формат    → транспорт отделён от компонента
```

---

## Ключевое: MCP-совместимость как транспортный адаптер

Чтобы заменить MCP, нужно чтобы **существующие MCP-клиенты работали без изменений**. Это значит наш сервер должен говорить на MCP-диалекте — и говорит, это один из транспортов.

Но при этом WIT-интерфейс становится **каноническим источником истины**:

```
WIT definition
    │
    ├── генерирует → MCP tool schema (JSON Schema)
    ├── генерирует → OpenAPI spec
    ├── генерирует → gRPC proto
    └── генерирует → TypeScript types
```

Разработчик описывает инструмент один раз в WIT — всё остальное производное.

---

## Путь замены MCP: три фазы

**Фаза 1: Совместимость**
Наш сервер — валидный MCP сервер. Агенты не замечают разницы. Разработчики получают wasm sandbox и типизацию как бонус.

```
Claude/Cursor/etc → MCP protocol → наш адаптер → wasm компонент
```

**Фаза 2: Расширения поверх MCP**
Добавляем то чего в MCP нет, через нестандартные методы или новый транспорт:

- Typed calls (бинарный, без JSON-Schema)
- Streaming results (wasi:io streams → SSE/WebSocket)
- Component composition (один endpoint, несколько скомпонованных компонентов)
- Capability negotiation (клиент и сервер договариваются о фичах)

**Фаза 3: Нативные клиенты**
Агенты и приложения начинают говорить напрямую на бинарном протоколе, минуя MCP JSON-RPC overhead. MCP остаётся legacy-транспортом.

---

## Самое важное для adoption

Техническое превосходство не гарантирует замену. Нужно:

**Developer experience лучше чем MCP:**
```rust
// Компонент пишется так (гипотетический SDK):
#[tool]
async fn search_web(query: String, limit: u32) -> Vec<SearchResult> {
    // ...
}
// WIT генерируется автоматически, MCP schema тоже
```

Против MCP сегодня:
```typescript
// MCP SDK — много бойлерплейта, нет типов на входе
server.tool("search_web", { query: z.string(), limit: z.number() }, async (args) => {
    // ...
})
```

**Портируемость существующих MCP серверов:**
Инструмент миграции: берёт существующий MCP сервер → оборачивает в wasm компонент автоматически или помогает с портированием.

---

## Что нужно зафиксировать в спецификации уже сейчас

Чтобы путь к замене был открыт — несколько принципов в дизайне:

1. **WIT как единственный IDL** — никакого параллельного JSON Schema, только генерация из WIT
2. **Версионирование интерфейсов** — WIT пакеты версионируются, клиенты декларируют что умеют
3. **Capability negotiation** в протоколе с первого дня — даже если фич пока мало
4. **MCP как один из транспортов**, не архитектурная основа

Хочешь проработать спецификацию capability negotiation или сначала зафиксируем финальную структуру WIT?



## Prompt:
3/5/2026, 12:28:16 AM

Для каждого tool нужна метадата, в которой должны быть, например, комментарии для агента



## Response:
3/5/2026, 12:28:37 AM

Да, это важно зафиксировать в WIT с самого начала. Давай проработаем что должно быть в метадате.

---

## Что нужно агенту vs разработчику

```
Потребитель метадаты:
├── Агент (LLM)
│   ├── описание что делает инструмент
│   ├── описание каждого параметра
│   ├── примеры вызовов
│   ├── когда использовать / когда не использовать
│   └── side effects (читает данные или меняет состояние?)
│
├── Разработчик приложения
│   ├── версия инструмента
│   ├── автор / источник
│   ├── требуемые capabilities (сеть, FS, и т.д.)
│   └── теги / категории
│
└── Runtime (host)
    ├── таймауты
    ├── идемпотентность
    └── retry-политика
```

---

## WIT с метадатой

```wit
package myorg:tool-platform@0.1.0;

interface tool-provider {

  record parameter-meta {
    name: string,
    description: string,         // для агента
    example: option<string>,     // JSON-значение как строка
    required: bool,
  }

  record tool-annotations {
    // для агента
    description: string,
    usage-hints: option<string>,      // когда использовать
    anti-usage-hints: option<string>, // когда НЕ использовать
    examples: list<string>,           // JSON примеры вызовов

    // side effects — агент должен понимать последствия
    read-only: bool,
    idempotent: bool,
    destructive: bool,

    // для разработчика и runtime
    version: string,
    tags: list<string>,
    timeout-ms: option<u32>,

    // required capabilities
    needs-network: bool,
    needs-filesystem: bool,
  }

  record tool-definition {
    name: string,
    parameters: list<parameter-meta>,
    annotations: tool-annotations,
  }

  // ...
}
```

---

## Проблема: WIT не поддерживает doc-комментарии в runtime

WIT комментарии (`///`) существуют только в исходнике, в бинарный `.wasm` они не попадают. Поэтому метадата должна быть **явными данными**, возвращаемыми из `list-tools` — что мы и делаем выше.

Но тогда возникает дублирование для разработчика компонента:

```rust
// Разработчик пишет это вручную — неудобно
ToolDefinition {
    name: "search_web".into(),
    parameters: vec![
        ParameterMeta {
            name: "query".into(),
            description: "Search query string".into(),
            // ...
        }
    ],
    annotations: ToolAnnotations {
        description: "Searches the web...".into(),
        // ...
    }
}
```

---

## Решение: макросы в guest SDK

```rust
#[tool(
    description = "Searches the web and returns relevant results",
    usage_hints = "Use when you need current information not in your training data",
    anti_usage_hints = "Don't use for simple factual questions you already know",
    tags = ["web", "search"],
    read_only = true,
)]
async fn search_web(
    #[param(description = "Search query", example = "\"rust async runtime\"")]
    query: String,

    #[param(description = "Maximum number of results", example = "10")]
    limit: u32,
) -> Vec<SearchResult> {
    // ...
}
```

Макрос генерирует и реализацию WIT-экспорта, и `list-tools` ответ с заполненной метадатой. Разработчик пишет один раз.

---

## Открытый вопрос

Нужна ли **локализация** описаний? Агент работает на разных языках, и описание `"Search the web"` на английском — это де-факто стандарт, но теоретически можно хранить `map<lang, description>`. Это усложняет структуру, но может быть важно для некоторых use-case.



## Prompt:
3/5/2026, 12:30:47 AM

Да, map lang/description ок



## Response:
3/5/2026, 12:31:02 AM

Тогда фиксируем это в структуре:

---

## Локализованные строки как примитив

Вместо того чтобы дублировать `option<string>` везде где может быть текст для агента — вводим отдельный тип:

```wit
/// Локализованная строка. Ключ — BCP 47 language tag ("en", "ru", "zh-Hans").
/// Агент или хост выбирает подходящую локаль, fallback на "en".
type localized-string = list<tuple<string, string>>;
```

---

## Обновлённые record'ы

```wit
record parameter-meta {
  name: string,                        // идентификатор, не локализуется
  description: localized-string,
  example: option<string>,             // JSON-значение, универсально
  required: bool,
}

record tool-annotations {
  // для агента — локализованные
  description: localized-string,
  usage-hints: option<localized-string>,
  anti-usage-hints: option<localized-string>,

  // примеры вызовов — JSON, язык не нужен
  examples: list<string>,

  // side effects
  read-only: bool,
  idempotent: bool,
  destructive: bool,

  // для runtime и разработчика — не локализуются
  version: string,
  tags: list<string>,
  timeout-ms: option<u32>,
  needs-network: bool,
  needs-filesystem: bool,
}
```

---

## В SDK макросе

```rust
#[tool(
    description = {
        en = "Searches the web and returns relevant results",
        ru = "Ищет информацию в интернете и возвращает релевантные результаты",
    },
    usage_hints = {
        en = "Use when you need current information not in your training data",
        ru = "Используй когда нужна актуальная информация, которой нет в обучающих данных",
    },
    read_only = true,
    tags = ["web", "search"],
)]
async fn search_web(
    #[param(
        description = {
            en = "Search query",
            ru = "Поисковый запрос",
        },
        example = "\"rust async runtime\""
    )]
    query: String,
) -> Vec<SearchResult> { ... }
```

---

## Вопрос про fallback на стороне хоста

Хост при трансляции в MCP или RPC должен выбрать одну локаль. Логика:

```
1. Клиент передаёт Accept-Language (или MCP negotiation)
2. Хост ищет точное совпадение → prefix совпадение ("zh" для "zh-Hans") → "en" → первый доступный
```

Это стоит зафиксировать в спецификации хоста, не в WIT — компонент просто возвращает все локали, выбор на стороне адаптера.

Двигаемся дальше к структуре session и call/result, или есть что добавить в метадату?



## Prompt:
3/5/2026, 12:31:51 AM

Wit records можно расширять со временем?



## Response:
3/5/2026, 12:32:09 AM

Нет, это одна из известных проблем WIT/Component Model.

---

## Как устроено сейчас

WIT record — это **структурный тип с фиксированными полями**. Добавление нового поля — breaking change, потому что:

- Бинарное представление фиксировано в скомпилированном `.wasm`
- Хост и гость должны иметь одинаковое представление record'а
- Нет понятия "unknown fields" как в protobuf

```wit
// v0.1 — компонент скомпилирован с этим
record tool-annotations {
  description: localized-string,
  read-only: bool,
}

// v0.2 — добавили поле
record tool-annotations {
  description: localized-string,
  read-only: bool,
  cost-estimate: option<u32>, // ← старый компонент не знает об этом поле
}
```

Старый `.wasm` с новым хостом — **линковка упадёт**.

---

## Варианты решения

**Вариант A: Версионирование через WIT пакеты**

```wit
package myorg:tool-platform@0.1.0;  // старый компонент
package myorg:tool-platform@0.2.0;  // новый компонент
```

Хост поддерживает несколько версий интерфейса одновременно. Компонент декларирует какую версию он реализует. Это официально рекомендуемый путь в Component Model.

Минус: хост должен поддерживать N версий интерфейса.

---

**Вариант B: Extensible через `extra-fields`**

```wit
record tool-annotations {
  // стабильные поля
  description: localized-string,
  read-only: bool,

  // escape hatch для расширений
  extensions: list<tuple<string, string>>,  // key → JSON value
}
```

Новые поля до стабилизации живут в `extensions`. Когда стабилизируются — переезжают в новую версию record'а.

Минус: теряем типизацию для расширений.

---

**Вариант C: Flat option-fields**

Все опциональные и будущие поля сразу делаем `option<T>`:

```wit
record tool-annotations {
  description: localized-string,
  read-only: bool,
  // зарезервировано под будущее, сейчас всегда none
  cost-estimate: option<u32>,
  retry-policy: option<retry-policy>,
}
```

Минус: record пухнет от `option`-полей которые никто не использует.

---

## Рекомендация

Комбинация A + B:

- **Версионирование пакетов** для breaking changes и крупных эволюций интерфейса
- **`extensions: list<tuple<string, string>>`** как стабильный escape hatch для экспериментальных метаданных

Это стандартная практика — так устроен, например, HTTP (заголовки как расширение) и gRPC (unknown fields в proto3).

Фиксируем этот подход и идём к session/call?



## Prompt:
3/5/2026, 12:32:55 AM

Да



## Response:
3/5/2026, 12:33:14 AM

Отлично. Фиксируем всё накопленное и переходим к session и call/result.

---

## Session lifecycle

```wit
interface tool-provider {

  resource session {
    constructor();

    list-tools: func() -> list<tool-definition>;

    call-tool: async func(call: tool-call) -> result<tool-result, tool-error>;

    // явное завершение сессии — компонент может освободить ресурсы
    close: func();
  }
}
```

Хост держит `session` handle живым между вызовами. Дроп handle'а = вызов `close`.

---

## Call и Result

```wit
record tool-call {
  id: string,                        // для корреляции в async контексте
  name: string,
  arguments: list<tuple<string, string>>,  // key → JSON value
  extensions: list<tuple<string, string>>,
}

record content-part {
  // тип: "text", "image", "resource", "audio" — расширяемо через extensions
  kind: string,
  data: string,           // текст или base64
  mime-type: option<string>,
  extensions: list<tuple<string, string>>,
}

record tool-result {
  id: string,             // совпадает с call.id
  content: list<content-part>,
  is-error: bool,
  extensions: list<tuple<string, string>>,
}

enum error-kind {
  not-found,        // инструмент не существует
  invalid-args,     // ошибка валидации аргументов
  timeout,
  capability-denied, // компонент запросил capability которой нет
  internal,
}

record tool-error {
  kind: error-kind,
  message: localized-string,
  extensions: list<tuple<string, string>>,
}
```

---

## Полный WIT на данный момент

```wit
package myorg:tool-platform@0.1.0;

interface types {
  type localized-string = list<tuple<string, string>>;

  record parameter-meta {
    name: string,
    description: localized-string,
    example: option<string>,
    required: bool,
    extensions: list<tuple<string, string>>,
  }

  record tool-annotations {
    description: localized-string,
    usage-hints: option<localized-string>,
    anti-usage-hints: option<localized-string>,
    examples: list<string>,
    read-only: bool,
    idempotent: bool,
    destructive: bool,
    version: string,
    tags: list<string>,
    timeout-ms: option<u32>,
    needs-network: bool,
    needs-filesystem: bool,
    extensions: list<tuple<string, string>>,
  }

  record tool-definition {
    name: string,
    parameters: list<parameter-meta>,
    annotations: tool-annotations,
  }

  record tool-call {
    id: string,
    name: string,
    arguments: list<tuple<string, string>>,
    extensions: list<tuple<string, string>>,
  }

  record content-part {
    kind: string,
    data: string,
    mime-type: option<string>,
    extensions: list<tuple<string, string>>,
  }

  record tool-result {
    id: string,
    content: list<content-part>,
    is-error: bool,
    extensions: list<tuple<string, string>>,
  }

  enum error-kind {
    not-found,
    invalid-args,
    timeout,
    capability-denied,
    internal,
  }

  record tool-error {
    kind: error-kind,
    message: localized-string,
    extensions: list<tuple<string, string>>,
  }
}

interface tool-provider {
  use types.{
    tool-definition, tool-call, tool-result, tool-error
  };

  resource session {
    constructor();
    list-tools: func() -> list<tool-definition>;
    call-tool: async func(call: tool-call) -> result<tool-result, tool-error>;
    close: func();
  }
}

world tools-world {
  export tool-provider;
}
```

---

## Открытые вопросы

Два момента которые стоит решить до scaffold хоста:

**1. Streaming results** — нужен ли `stream<content-part>` вместо `list<content-part>` в result? Актуально для long-running tools (генерация текста, прогресс загрузки). В wasip3 это `async func() -> stream<content-part>`.

**2. Cancellation** — если `call-tool` async, нужна ли возможность отменить вызов? В Component Model это через дроп future на стороне хоста.



## Prompt:
3/5/2026, 12:35:55 AM

Может ли mcp отдавать результат постепенно?



## Response:
3/5/2026, 12:36:12 AM

Да, в MCP есть механизм для этого — но ограниченный.

---

## Что есть в MCP сейчас

**Notifications** — сервер может слать `notifications/progress` пока выполняется tool call:

```json
// Клиент вызывает
{"method": "tools/call", "id": "1", "params": {"name": "search", ...}}

// Сервер шлёт по ходу выполнения
{"method": "notifications/progress", "params": {"progressToken": "1", "progress": 0.5, "total": 1.0}}

// И финальный результат
{"id": "1", "result": {"content": [...]}}
```

Это **прогресс**, а не стриминг контента. Финальный результат всё равно один батч.

---

## Чего в MCP нет

Нет возможности отдавать **частичный контент** по мере готовности — например, первые абзацы текста пока остальные ещё генерируются. Результат tool call всегда атомарный.

SSE-транспорт технически позволяет стримить, но протокол этого не описывает для tools.

---

## Что это означает для нашего стандарта

Это ещё одно место где мы можем быть лучше MCP. `stream<content-part>` в wasip3 маппится естественно:

```
wasm stream<content-part>
    → SSE events (MCP транспорт)
    → chunked HTTP (RPC транспорт)
    → async iterator (нативный клиент)
```

MCP-адаптер может транслировать первые части как `notifications/progress` с контентом внутри, а финальный пустой результат как завершение — это совместимо с существующими MCP клиентами, хотя и костыльно.

---

Значит `stream<content-part>` в result стоит заложить с самого начала. Как тебе такой вариант для `call-tool`:

```wit
// Вариант A: всегда stream
call-tool: async func(call: tool-call) -> result<stream<content-part>, tool-error>;

// Вариант B: компонент выбирает
call-tool: async func(call: tool-call) -> result<tool-result-or-stream, tool-error>;

variant tool-result-or-stream {
  complete(tool-result),
  streaming(stream<content-part>),
}
```

Вариант B даёт компоненту выбор — простые инструменты возвращают сразу, сложные стримят. Но усложняет хост и клиент. Вариант A проще — хост всегда читает stream, просто для атомарных результатов он завершается сразу с одним элементом.



## Prompt:
3/5/2026, 12:37:03 AM

Вариант А



## Response:
3/5/2026, 12:37:22 AM

Принято. Тогда финализируем `call-tool` и обновляем WIT.

---

## Что меняется

`tool-result` теряет `content` — он теперь в стриме. Остаётся только метадата завершения:

```wit
record tool-result {
  id: string,
  is-error: bool,              // финальный статус после стрима
  extensions: list<tuple<string, string>>,
}
```

Но тут проблема — если `is-error` в финальном record'е, то клиент узнаёт об ошибке только после того как получил весь стрим. Для ошибок валидации аргументов это плохо.

---

## Решение: ошибки на двух уровнях

```wit
// Ранняя ошибка (до стрима) — через result
// Ошибка в процессе — через error-part в стриме

variant stream-event {
  content(content-part),
  error(tool-error),    // может прийти в любой момент, завершает стрим
}

resource session {
  constructor();
  list-tools: func() -> list<tool-definition>;
  call-tool: async func(call: tool-call) -> result<stream<stream-event>, tool-error>;
  close: func();
}
```

Схема потока:

```
result::ok  → stream открыт
    ├── stream-event::content(part) × N
    └── stream-event::error(e)  ← опционально, завершает стрим

result::err → ранняя ошибка, стрим не открывался
```

---

## Обновлённый полный WIT

```wit
package myorg:tool-platform@0.1.0;

interface types {
  type localized-string = list<tuple<string, string>>;

  record parameter-meta {
    name: string,
    description: localized-string,
    example: option<string>,
    required: bool,
    extensions: list<tuple<string, string>>,
  }

  record tool-annotations {
    description: localized-string,
    usage-hints: option<localized-string>,
    anti-usage-hints: option<localized-string>,
    examples: list<string>,
    read-only: bool,
    idempotent: bool,
    destructive: bool,
    version: string,
    tags: list<string>,
    timeout-ms: option<u32>,
    needs-network: bool,
    needs-filesystem: bool,
    extensions: list<tuple<string, string>>,
  }

  record tool-definition {
    name: string,
    parameters: list<parameter-meta>,
    annotations: tool-annotations,
  }

  record tool-call {
    id: string,
    name: string,
    arguments: list<tuple<string, string>>,
    extensions: list<tuple<string, string>>,
  }

  record content-part {
    kind: string,
    data: string,
    mime-type: option<string>,
    extensions: list<tuple<string, string>>,
  }

  enum error-kind {
    not-found,
    invalid-args,
    timeout,
    capability-denied,
    internal,
  }

  record tool-error {
    kind: error-kind,
    message: localized-string,
    extensions: list<tuple<string, string>>,
  }

  variant stream-event {
    content(content-part),
    error(tool-error),
  }
}

interface tool-provider {
  use types.{
    tool-definition,
    tool-call,
    stream-event,
    tool-error,
  };

  resource session {
    constructor();
    list-tools: func() -> list<tool-definition>;
    call-tool: async func(call: tool-call) -> result<stream<stream-event>, tool-error>;
    close: func();
  }
}

world tools-world {
  export tool-provider;
}
```

---

## Как это маппится на транспорты

```
stream-event::content  → SSE "data: {...}"
                       → MCP notifications/progress (с контентом)
                       → chunked HTTP chunk

stream-event::error    → SSE "event: error"
                       → финальный MCP result с is-error: true

result::err            → MCP error response (до открытия стрима)
                       → HTTP 4xx
```

---

Осталось проработать две темы перед scaffold хоста:

**Cancellation** — дроп stream'а на стороне хоста должен сигнализировать компоненту об отмене. В wasip3 это автоматически через дроп stream handle — стоит ли это явно документировать в спецификации?

**Capabilities** — как компонент декларирует что ему нужна сеть или FS, и как хост это enforcement'ит через wasmtime linker?



## Prompt:
3/5/2026, 12:40:29 AM

Cancellation стоит задокументировать.
Capabilities — не знаю



## Response:
3/5/2026, 12:40:51 AM

По cancellation всё понятно. По capabilities давай разберём варианты чтобы ты мог принять решение.

---

## Cancellation — документируем так

```
Контракт отмены:
1. Хост дропает stream handle → wasmtime автоматически отменяет future
2. Компонент получает отмену через wasi:io механизм (poll возвращает closed)
3. Компонент должен освободить ресурсы и завершиться чисто
4. Хост не обязан ждать завершения компонента после дропа
5. Частично отправленные content-part'ы до отмены считаются доставленными
```

Это стоит зафиксировать в спецификации как отдельный раздел, не в WIT — WIT это только интерфейс, поведение описывается в prose.

---

## Capabilities — три подхода

**Вариант A: Декларация в метадате, enforcement на хосте**

Компонент декларирует в `tool-annotations` что ему нужно (`needs-network`, `needs-filesystem`). Хост при линковке решает — давать или нет:

```
needs-network: true  → хост линкует wasi:sockets
needs-network: false → хост не линкует, любой сетевой вызов = trap
```

Плюсы: просто, работает сейчас, без изменений WIT.
Минусы: декларация не верифицируется — компонент может соврать или не знать что ему нужно. Хост должен доверять метадате.

---

**Вариант B: Статический анализ `.wasm`**

Хост при загрузке компонента анализирует его импорты — если компонент импортирует `wasi:sockets`, значит нужна сеть. Метадата генерируется автоматически.

```rust
// Хост при загрузке
let required_caps = analyze_imports(&wasm_bytes);
// → { needs_network: true, needs_filesystem: false }
```

Плюсы: верифицируемо, не зависит от честности разработчика.
Минусы: нужна реализация анализатора, чуть сложнее.

---

**Вариант C: Capability-based через WIT импорты**

Компонент явно импортирует capabilities через WIT:

```wit
world tools-world {
  export tool-provider;

  // явные импорты = явные capabilities
  import wasi:sockets/tcp;
  import wasi:filesystem/types;
}
```

Хост видит `world` и знает что линковать. Это идиоматично для Component Model.

Плюсы: самодокументируемо, верифицируемо, стандартный подход.
Минусы: разработчик должен явно описывать `world` — чуть больше бойлерплейта.

---

## Рекомендация

Вариант C как основа — это правильный путь для Component Model. Вариант B как дополнение — хост может анализировать импорты и предупреждать если `world` не декларирует то что реально используется. Вариант A (`needs-network` в аннотациях) оставить как **производное** — хост заполняет его автоматически из анализа импортов, не вручную разработчиком.

```
Разработчик описывает world с импортами (C)
    → хост анализирует импорты (B)
        → автоматически заполняет needs-* в annotations (A)
            → MCP/RPC клиент видит capabilities в метадате
```

Как тебе такая схема?



## Prompt:
3/5/2026, 12:42:28 AM

+



## Response:
3/5/2026, 12:42:47 AM

Отлично. Тогда обновляем спецификацию — `needs-*` поля в `tool-annotations` становятся производными, и документируем это явно.

---

## Что меняется в WIT

`needs-network` и `needs-filesystem` убираем из `tool-annotations` — они больше не декларируются разработчиком вручную. Вместо этого вводим отдельный record для capabilities, который хост заполняет сам:

```wit
// Заполняется хостом при загрузке компонента, не разработчиком
record component-capabilities {
  network: bool,
  filesystem: bool,
  threads: bool,
  // расширяемо по мере роста wasi namespace
  extensions: list<tuple<string, string>>,
}
```

И добавляем его в `component-info` — метадату уровня компонента, не отдельного инструмента:

```wit
record component-info {
  name: string,
  version: string,
  description: localized-string,
  capabilities: component-capabilities,
  extensions: list<tuple<string, string>>,
}
```

---

## Два уровня метадаты

Это важное разделение которое проявилось:

```
component-info        — уровень компонента (одна штука на весь .wasm)
  ├── name, version
  ├── description
  └── capabilities    ← хост заполняет из анализа импортов

tool-definition       — уровень инструмента (одна штука на каждый tool)
  ├── name
  ├── parameters
  └── annotations     ← разработчик заполняет через SDK макросы
```

---

## Где живёт component-info

Не в `session` — она известна до создания сессии. Отдельный экспорт:

```wit
interface component-metadata {
  use types.{ component-info };
  get-info: func() -> component-info;
}

world tools-world {
  export component-metadata;
  export tool-provider;
}
```

Хост вызывает `get-info` один раз при загрузке, кэширует, дополняет `capabilities` из анализа импортов, и отдаёт клиентам.

---

## Обновлённый полный WIT

```wit
package myorg:tool-platform@0.1.0;

interface types {
  type localized-string = list<tuple<string, string>>;

  // --- Component level ---

  record component-capabilities {
    network: bool,
    filesystem: bool,
    threads: bool,
    extensions: list<tuple<string, string>>,
  }

  record component-info {
    name: string,
    version: string,
    description: localized-string,
    capabilities: component-capabilities,
    extensions: list<tuple<string, string>>,
  }

  // --- Tool level ---

  record parameter-meta {
    name: string,
    description: localized-string,
    example: option<string>,
    required: bool,
    extensions: list<tuple<string, string>>,
  }

  record tool-annotations {
    description: localized-string,
    usage-hints: option<localized-string>,
    anti-usage-hints: option<localized-string>,
    examples: list<string>,
    read-only: bool,
    idempotent: bool,
    destructive: bool,
    tags: list<string>,
    timeout-ms: option<u32>,
    extensions: list<tuple<string, string>>,
  }

  record tool-definition {
    name: string,
    parameters: list<parameter-meta>,
    annotations: tool-annotations,
  }

  // --- Call / Result ---

  record tool-call {
    id: string,
    name: string,
    arguments: list<tuple<string, string>>,
    extensions: list<tuple<string, string>>,
  }

  record content-part {
    kind: string,
    data: string,
    mime-type: option<string>,
    extensions: list<tuple<string, string>>,
  }

  enum error-kind {
    not-found,
    invalid-args,
    timeout,
    capability-denied,
    internal,
  }

  record tool-error {
    kind: error-kind,
    message: localized-string,
    extensions: list<tuple<string, string>>,
  }

  variant stream-event {
    content(content-part),
    error(tool-error),
  }
}

interface component-metadata {
  use types.{ component-info };
  get-info: func() -> component-info;
}

interface tool-provider {
  use types.{
    tool-definition,
    tool-call,
    stream-event,
    tool-error,
  };

  resource session {
    constructor();
    list-tools: func() -> list<tool-definition>;
    call-tool: async func(call: tool-call) -> result<stream<stream-event>, tool-error>;
    close: func();
  }
}

world tools-world {
  export component-metadata;
  export tool-provider;
}
```

---

Спецификация выглядит достаточно полной для первого прототипа. Готов переходить к scaffold хоста на Rust, или есть что ещё проработать в дизайне?



## Prompt:
3/5/2026, 12:46:34 AM

Make capabilities extensible from the start, do not hardcore network, fs and others. Just define them as a party of spec



## Response:
3/5/2026, 12:46:46 AM

Good call. Capabilities should be an open registry, not a hardcoded enum.

---

## Подход: capability как именованный URI

По аналогии с wasi namespace — capabilities идентифицируются строкой:

```
wasi:sockets/tcp
wasi:filesystem/types
wasi:threads
myorg:gpu-access
myorg:hardware/camera
```

Строка = namespace + name, что позволяет третьим сторонам определять свои capabilities без конфликтов.

---

## Обновлённый WIT

```wit
record capability {
  // URI вида "wasi:sockets/tcp" или "myorg:gpu-access"
  id: string,
  // человекочитаемое описание для UI и агентов
  description: option<localized-string>,
  extensions: list<tuple<string, string>>,
}

record component-capabilities {
  // хост заполняет из анализа wasm-импортов
  required: list<capability>,
  // capabilities которые компонент запрашивает опционально
  optional: list<capability>,
  extensions: list<tuple<string, string>>,
}
```

---

## Стандартные capability ID — часть спецификации

Спека определяет well-known идентификаторы, хост знает как их маппить на wasmtime linker:

```
# Стандартные (определены в myorg:tool-platform spec)
wasi:sockets/tcp
wasi:sockets/udp
wasi:filesystem/types
wasi:threads
wasi:keyvalue/store
wasi:http/outgoing-handler

# Вендорные (за пределами спеки, хост может не знать)
acme:gpu/compute
acme:hardware/camera
```

Хост при встрече с неизвестным capability ID — либо игнорирует, либо отказывает в загрузке компонента в зависимости от политики (`strict` / `permissive`).

---

## Обновлённый component-info

```wit
record component-info {
  name: string,
  version: string,
  description: localized-string,
  capabilities: component-capabilities,
  extensions: list<tuple<string, string>>,
}
```

Без изменений — просто `component-capabilities` теперь открытый.

---

Готов к scaffold хоста?



## Prompt:
3/5/2026, 12:48:11 AM

Как назвать новый стандарт?



## Response:
3/5/2026, 12:48:22 AM

Хороший вопрос. Давай подумаем системно.

---

## Что должно отражать название

- Компонентная природа (wasm components)
- Универсальность — и для агентов, и для приложений
- Не привязано к конкретному транспорту или протоколу
- Желательно короткое, запоминаемое

---

## Варианты

**По сути технологии:**
- **WCT** — WebAssembly Component Tools
- **WACT** — WebAssembly Agent Component Tools
- **Capsule** — компонент как изолированная капсула с инструментами

**По назначению:**
- **Forge** — инструменты куются в компоненты
- **Toolpack** / **Toolbox** — набор инструментов в компоненте
- **Kit** — универсально, но generic

**По аналогии с MCP:**
- **TCP** — Tool Component Protocol *(конфликт с сетевым протоколом, плохо)*
- **TCP** — отпадает
- **UTP** — Universal Tool Protocol
- **CTP** — Component Tool Protocol

**Более оригинальные:**
- **Nexus** — точка соединения агентов и приложений
- **Conduit** — канал между агентом и инструментом
- **Prism** — один компонент, много интерфейсов

---

## Моё ощущение

**CTP** (Component Tool Protocol) — функционально точно, хорошо рифмуется с MCP в контексте замены.

**Capsule** — образно и технически точно: wasm sandbox = капсула с инструментами внутри.

Что резонирует?



## Prompt:
3/5/2026, 12:49:11 AM

What about ACT?



## Response:
3/5/2026, 12:49:20 AM

**ACT** — Agent Component Tools.

Хорошо работает:

- **Короткое** — легко произносится, легко запоминается
- **ACT** как глагол — компонент *действует*, выполняет инструменты
- **Расшифровка естественная** — Agent Component Tools точно описывает суть
- **Домен** — `act` скорее всего свободен как название проекта/crate
- **Рифмуется с MCP** в позиционировании — "MCP to ACT migration"

Потенциальные конфликты которые стоит проверить:
- GitHub: есть GitHub Actions `act` (локальный runner) — в другой нише, не конфликт по смыслу
- crates.io: `act` скорее всего занят, но `act-sdk`, `act-host`, `act-cli` — скорее всего свободны

---

## Naming конвенция для экосистемы

```
Спека:         ACT spec / ACT standard
Пакеты WIT:    myorg:act@0.1.0  →  потом  act:core@0.1.0
Rust crates:   act-host / act-cli / act-server / act-sdk
Расширение:    .act.wasm  или просто .wasm с ACT world внутри
Команда:       act run / act list / act call
```

Берём ACT?



## Prompt:
3/5/2026, 12:50:09 AM

Какие ещё конфликты могут быть?



## Response:
3/5/2026, 12:50:31 AM

Давай проверю что есть в реальности.

````plaintext
Web Search: ACT protocol standard software
````

> **Administration Manual - the ACT - Standard Time - Online** [act.org](https://www.act.org/content/dam/act/unsecured/documents/AdministrationManual-StandardTimeOnlineTesting.pdf)
>
> **ACTpro Software | acre security** [acresecurity.com](https://products.acresecurity.com/access-control/systems/actpro/software-and-licences/actpro-software)
>
> **Act! Software Overview 2026 - Features & Pricing** [softwareadvice.com](https://www.softwareadvice.com/crm/act-crm-profile/)
>
> **Act! Software Downloads | MondoCRM** [mondocrm.com](https://www.mondocrm.com/pages/solutions/crm/act-crm/act-downloads/)
>
> **Access control Integration – ACT Enterprise – Vanderbilt SPC** [spcsupportinfo.com](https://www.spcsupportinfo.com/SPCConnectPro/?page_id=10685)
>
> **ACT-R » Software** [cmu.edu](http://act-r.psy.cmu.edu/software/)
>
> **Act! Pro Software for Windows | Features and Pricing** [actplatinum.com](https://actplatinum.com/act-pro-software/)
>
> **User's Guide - Act!** [act.com](http://download.act.com/actguide60.pdf)
>
> **ACT! CRM Software Premium versus Standard ACT software review** [act4advisors.com](http://www.act4advisors.com/Premium_vs_Standard_Act.asp)
>
> **Act! Software 2026: Features, Integrations, Pros & Cons | Capterra** [capterra.com](https://www.capterra.com/p/175860/Act/)
>
````plaintext
Web Search: ACT crates.io rust
````

> **act - crates.io: Rust Package Registry** [crates.io](https://crates.io/crates/act)
>
> **acts - crates.io: Rust Package Registry** [crates.io](https://crates.io/crates/acts)
>
> **act-zero - crates.io: Rust Package Registry** [crates.io](https://crates.io/crates/act-zero)
>
> **actix - crates.io: Rust Package Registry** [crates.io](https://crates.io/crates/actix)
>
> **crates.io: Rust Package Registry** [crates.io](https://crates.io/crates/act/0.1.0)
>
> **act-file - crates.io: Rust Package Registry** [crates.io](https://crates.io/crates/act-file)
>
> **Publishing a Crate to Crates.io - The Rust Programming Language** [rust-lang.org](https://doc.rust-lang.org/book/ch14-02-publishing-to-crates-io.html)
>
> **actix-rt - crates.io: Rust Package Registry** [crates.io](https://crates.io/crates/actix-rt)
>
> **actix-http - crates.io: Rust Package Registry** [crates.io](https://crates.io/crates/actix-http)
>
> **GitHub - rust-lang/crates.io: The Rust package registry · GitHub** [github.com](https://github.com/rust-lang/crates.io)
>
````plaintext
Web Search: ACT "agent component" OR "agentic component" protocol specification 2024 2025
````

> **AI agent - Wikipedia** [wikipedia.org](https://en.wikipedia.org/wiki/AI_agent)
>
Вот полная картина конфликтов:

---

## Конфликты по категориям

**Серьёзные — прямое пересечение названия:**
- **Act!** — CRM-система с 1987 года, зарегистрированная торговая марка Sage/Swiftpage. Известна в enterprise-мире
- **`act`** на crates.io — занят (workflow engine). `acts`, `act-zero`, `act-file` тоже заняты
- **`act`** на GitHub — некластеризованный runner для GitHub Actions, популярный инструмент

**Средние — в смежных областях:**
- **ACT-R** — когнитивная архитектура из Carnegie Mellon (Adaptive Control of Thought–Rational). В академической среде AI это известная аббревиатура
- **ACTpro** — система контроля доступа от Vanderbilt/acre security

**Слабые — другие домены:**
- **ACT** — стандартизированный тест (American College Testing). Огромный бренд в США, но совсем другая ниша

---

## Вывод

Главная проблема — `act` на crates.io занят, и Act! CRM как торговая марка. Для open-source протокола это создаёт путаницу при поиске.

Варианты выхода:
- Использовать префикс: **`wact`** (WebAssembly Agent Component Tools) — crates свободнее, поиск однозначнее
- Полное название **ACT** оставить как название спецификации, а crate-ы называть `act-host`, `act-sdk` и т.д. — многие из них скорее всего свободны
- Выбрать другое название

Как относишься к `wact`?



## Prompt:
3/5/2026, 12:51:08 AM

Как звучит WACT?



## Response:
3/5/2026, 12:51:20 AM

Не очень.

**WACT** произносится либо как "wakt" (похоже на "whacked" — ударенный/сумасшедший в английском сленге), либо как "вакт" — нейтрально но бессмысленно.

Теряется главное преимущество ACT — слово-глагол с понятным смыслом.

---

## Альтернативные подходы к проблеме имени

**Оставить ACT, решить проблему crates через namespace:**
```
crates: act-host, act-sdk, act-cli, act-server
WIT:    act:core@0.1.0
GitHub: github.com/yourorg/act-spec
```
Крейт `act` занят, но `act-host` и остальные скорее всего свободны. Многие протоколы так живут — `mcp` на crates.io тоже занят, но `rmcp`, `mcp-sdk` и т.д. свободны.

**Или поискать близкие по духу незанятые имена:**
- **Tura** — tool runtime abstraction (абстрактно, но свободно)
- **Nexus** — уже упоминали, но занят везде
- **Facet** — компонент как грань, через которую агент видит возможности
- **Invoke** / **Invok** — по действию, но generic

---

Мне кажется ACT стоит оставить. Конфликт с CRM-системой 1987 года в developer-сообществе не будет проблемой — аудитории не пересекаются. А `act` на crates.io решается префиксами.

Что думаешь?



## Prompt:
3/5/2026, 12:52:22 AM

Что по этому названию в других экосистемах (не rust)



## Response:
3/5/2026, 12:52:40 AM



````plaintext
Web Search: ACT npm package
````

> **GitHub - nektos/act: Run your GitHub Actions locally 🚀** [github.com](https://github.com/nektos/act)
>
> **npm | Profile** [npmjs.com](https://www.npmjs.com/~act)
>
> **Usage guide - act - User Guide | Manual | Docs | Documentation** [nektosact.com](https://nektosact.com/usage/)
>
> **act-master-cli - npm** [npmjs.com](https://www.npmjs.com/package/act-master-cli)
>
> **GitHub - kiegroup/act-js: A node.js wrapper for nektos/act to programmatically run your github actions locally** [github.com](https://github.com/kiegroup/act-js)
>
> **Github Actions locally with act | Infralovers** [infralovers.com](https://www.infralovers.com/blog/2024-08-14-github-actions-locally/)
>
> **How to Run GitHub Actions Locally Using the act CLI Tool** [freecodecamp.org](https://www.freecodecamp.org/news/how-to-run-github-actions-locally/)
>
> **@act/core CDN by jsDelivr - A CDN for npm and GitHub** [jsdelivr.com](https://www.jsdelivr.com/package/npm/@act/core)
>
> **A guide to using act with GitHub Actions - LogRocket Blog** [logrocket.com](https://blog.logrocket.com/guide-using-act-github-actions/)
>
> **@artalar/act - npm** [npmjs.com](https://www.npmjs.com/package/@artalar/act)
>
````plaintext
Web Search: ACT PyPI python package
````

> **act-api · PyPI** [pypi.org](https://pypi.org/project/act-api/)
>
> **act-atmos · PyPI** [pypi.org](https://pypi.org/project/act-atmos/)
>
> **act-admin 2.1.0 on PyPI - Libraries.io - security & maintenance data for open source software** [libraries.io](https://libraries.io/pypi/act-admin)
>
> **act_python · PyPI** [pypi.org](https://pypi.org/project/act_python/)
>
> **actr · PyPI** [pypi.org](https://pypi.org/project/actr/)
>
> **act-types·PyPI** [pypi.org](https://pypi.org/project/act-types/)
>
> **act-admin · PyPI** [pypi.org](https://pypi.org/project/act-admin/)
>
> **act-atmos 1.1.9 on PyPI - Libraries.io** [libraries.io](https://libraries.io/pypi/act-atmos)
>
> **act · PyPI** [pypi.org](https://pypi.org/project/act/)
>
> **Installation — ACT Documentation** [github.io](https://arm-doe.github.io/ACT/userguide/installation.html)
>
Полная картина по экосистемам:

---

## npm (JavaScript/TypeScript)

- `act` — занят (заброшенный reactive framework, 2016)
- `@act/core` — занят (тот же заброшенный проект)
- `act-master-cli` — CLI для TypeScript actions
- `nektos/act` — очень популярный инструмент для локального запуска GitHub Actions (~60k stars). **Это самый серьёзный конфликт** — developer-аудитория та же самая

## PyPI (Python)

- `act` — занят (пустой пакет 2016)
- `act-atmos` — Atmospheric data Community Toolkit (NASA/ARM)
- `act-api`, `act-types`, `act-admin` — экосистема ACT Platform (threat intelligence от mnemonic)
- `actr` — реализация когнитивной архитектуры ACT-R

## Go

- `nektos/act` — тот же GitHub Actions runner, написан на Go

---

## Итог

Самый болезненный конфликт — **nektos/act** (GitHub Actions runner). Это популярный dev-инструмент, который при поиске "act cli tool" будет выскакивать везде. Аудитория разработчиков полностью пересекается с нашей.

На PyPI `act` занят, но пакет мёртвый — технически можно запросить через PEP 541, но это долго.

---

## Вывод

ACT как название спецификации — окей, конфликта по смыслу нет. Но `act` как имя CLI-команды и пакетов во всех экосистемах — проблемно. Нужен либо префикс, либо другое название.

Варианты которые стоит проверить: **Capsule**, **Facet**, **Invoke**, или что-то совсем новое. Хочешь поискать в другом направлении?



## Prompt:
3/5/2026, 12:53:56 AM

Можно ли как-то монетизировать работы по этому стандарту? Сделать потом стартап?



## Response:
3/5/2026, 12:54:23 AM

Хороший вопрос, и отвечу честно — монетизировать открытый стандарт сложно, но есть рабочие модели.

---

## Как монетизируют открытые стандарты и протоколы

**Модель 1: Managed Registry / Marketplace**
Стандарт открытый, но реестр компонентов — платный для публикации или потребления.
Пример: npm (бесплатно для open-source, платно для private packages).

Применительно к ACT:
```
Публичные компоненты — бесплатно
Приватные компоненты — подписка
Верифицированные / enterprise компоненты — платно
```

**Модель 2: Managed Runtime (Cloud)**
Хостинг компонентов как сервис — ты не запускаешь wasm локально, а вызываешь через API.
Пример: Cloudflare Workers, Fastly Compute.

```
ACT Cloud: загрузи компонент → получи endpoint
Платишь за вызовы, время выполнения, трафик
```
Это очень логично для агентских use-case — агент вызывает инструменты через HTTP, не заботясь о runtime.

**Модель 3: Enterprise Support / Certification**
Стандарт открытый, но:
- Сертификация компонентов (security audit, performance)
- Enterprise SLA для runtime
- Приоритетная поддержка

Пример: Red Hat (открытый Linux, платная поддержка).

**Модель 4: Tooling**
Открытый стандарт, но проприетарные инструменты разработки:
- IDE плагины
- Визуальный редактор компонентов
- Monitoring / observability для компонентов в продакшне
- Автоматическая генерация компонентов из OpenAPI / существующих MCP серверов

**Модель 5: Стандарт как leverage для консалтинга**
Ты автор стандарта → тебя нанимают внедрять его в крупных компаниях.
Не стартап, но хороший cash flow на старте.

---

## Реалистичная траектория стартапа

```
Сейчас          → Открытая спецификация + референсная реализация
                  (репутация, community)

6-12 месяцев    → ACT Cloud в бете
                  (managed runtime, платишь за вызовы)

12-24 месяца    → Marketplace компонентов
                  (реестр, монетизация через private/verified)

24+ месяцев     → Enterprise tier
                  (on-premise runtime, SLA, сертификация)
```

---

## Главный риск

Anthropic, Microsoft или другой крупный игрок может принять похожий стандарт и задавить весь рынок. MCP уже от Anthropic — если они расширят его в сторону wasm компонентов, это убьёт независимый стандарт.

**Защита от этого** — скорость adoption и качество tooling до того как крупные игроки обратят внимание. У тебя есть техническое преимущество (wasm sandbox, типизация, stateful) которого в MCP нет и быстро не появится.

---

## Самый перспективный вектор

**ACT Cloud** — managed runtime для агентных инструментов. Рынок агентов растёт экспоненциально, каждому агенту нужны инструменты, никто не хочет разворачивать wasm runtime самостоятельно. Это SaaS с понятной unit-экономикой (вызовы/время).

Это примерно то что делает **E2B** (sandbox для агентов) — но на уровне стандартизированных компонентов, что даёт экосистемный эффект.

Интересно двигаться в эту сторону, или пока фокус на технической реализации?



## Prompt:
3/5/2026, 12:55:39 AM

1235 все отличные



## Response:
3/5/2026, 12:55:47 AM

Отлично, значит фиксируем бизнес-модель:

---

## Четыре направления монетизации

**1. Managed Registry** — реестр компонентов, платно для приватных и верифицированных пакетов

**2. ACT Cloud** — managed runtime, платишь за вызовы и время выполнения. Главный приоритет — рынок агентов растёт, никто не хочет держать wasm runtime самостоятельно

**3. Enterprise Support / Certification** — SLA, security audit компонентов, on-premise runtime для корпоративных клиентов

**4. Tooling** — IDE плагины, визуальный редактор, observability, автогенерация компонентов из OpenAPI/MCP

---

## Приоритет запуска

Логичная последовательность:

```
Открытая спека + референсная реализация  ← сейчас
        ↓
    ACT Cloud beta                        ← первая монетизация
        ↓
    Registry + Marketplace                ← экосистемный эффект
        ↓
    Enterprise tier                       ← масштаб
```

Tooling можно делать параллельно с Cloud — хорошее tooling ускоряет adoption, что напрямую влияет на выручку Cloud.

---

Возвращаемся к технической реализации? Готов скаффолдить host-крейт.



## Prompt:
3/5/2026, 12:55:57 AM

Не 4, а 5



## Response:
3/5/2026, 12:56:05 AM

Ты имеешь в виду пункт 5 — консалтинг?

Тогда картина такая: все пять направлений рабочие, и консалтинг особенно ценен на раннем этапе — пока Cloud и Registry ещё не приносят стабильную выручку, внедрение стандарта в крупные компании даёт живые деньги и одновременно создаёт reference customers, что ускоряет adoption.

Типичная схема:
```
Ранняя стадия:  консалтинг кормит команду + множит adoption
Средняя стадия: Cloud и Registry дают recurring revenue
Поздняя стадия: Enterprise tier + консалтинг как premium услуга
```

Единственный риск консалтинга — он плохо масштабируется и отвлекает от продукта. Поэтому важно с самого начала ограничивать его по времени и позиционировать как "внедрение стандарта", а не "разработка на заказ".

Готов переходить к scaffold хоста?



## Prompt:
3/5/2026, 12:56:36 AM

4 ограничивает развитие стандарта. Tooling должен быть свободный



## Response:
3/5/2026, 12:56:44 AM

Абсолютно верно. Проприетарный tooling создаёт vendor lock-in вокруг стандарта — это отпугивает contributors и замедляет adoption. Хороший tooling должен быть частью экосистемы, а не барьером.

Пример из истории: если бы npm сделал `package.json` редактор платным, Node.js экосистема не выросла бы так быстро.

Значит финальная модель:

```
Открыто и бесплатно:
├── Спецификация
├── Референсная реализация (host lib)
├── CLI
├── SDK (Rust, Python, ...)
└── Весь tooling (IDE плагины, генераторы, observability)

Монетизация:
├── ACT Cloud (managed runtime, pay-per-call)
├── Registry (private/verified компоненты)
├── Enterprise (SLA, on-premise, audit)
└── Консалтинг (внедрение на раннем этапе)
```

Это классическая модель open-core без закрытого core — всё что нужно разработчику бесплатно, деньги на инфраструктуре и сервисах.

Переходим к коду?



## Prompt:
3/5/2026, 12:58:59 AM

А вообще, насколько быстро бы здорово рассматривать этот протокол как самодокументируемый универсальный RPC-протокол



## Response:
3/5/2026, 12:59:25 AM

Отличное наблюдение. По сути ты уже почти там.

---

## Что уже есть для универсального RPC

WIT уже даёт всё что нужно для самодокументируемого RPC:

```
Типизированные вызовы        ✓  (WIT types)
Схема интерфейса             ✓  (WIT = IDL)
Версионирование              ✓  (пакеты с версиями)
Локализованные описания      ✓  (уже в спеке)
Streaming                    ✓  (stream<T>)
Расширяемость                ✓  (extensions everywhere)
Генерация клиентов           ✓  (из WIT можно генерить биндинги)
```

Разница с существующими RPC (gRPC, Thrift, Cap'n Proto) — компонент **сам является реализацией**, а не просто схемой. Ты не описываешь интерфейс отдельно от кода — компонент и есть интерфейс плюс реализация в одном `.wasm` файле.

---

## Что нужно добавить чтобы стать полноценным RPC

Сейчас спека заточена под tools — один паттерн вызова (`call-tool`). Для универсального RPC нужно чуть расширить мышление:

```wit
// Сейчас — специализировано под tools
interface tool-provider {
  resource session {
    call-tool: async func(call: tool-call) -> result<stream<stream-event>, tool-error>;
  }
}

// Для универсального RPC — любой экспортируемый WIT интерфейс
// уже IS an RPC интерфейс
interface payment-processor {
  resource session {
    charge: async func(amount: u64, currency: string) -> result<receipt, payment-error>;
    refund: async func(tx-id: string) -> result<unit, payment-error>;
  }
}
```

То есть `tool-provider` — это один из возможных интерфейсов, а не единственный.

---

## Архитектурный сдвиг

```
Текущее мышление:
  "Протокол для agent tools с MCP-совместимостью"

Расширенное мышление:
  "Универсальный RPC где wasm компонент = единица деплоя,
   а tool-provider — один из стандартных интерфейсов"
```

Это меняет позиционирование радикально:

```
Узкое:   конкурент MCP
Широкое: конкурент gRPC + Docker одновременно
```

Компонент как единица деплоя с типизированным интерфейсом — это то чем Docker никогда не был (Docker не знает что внутри контейнера), и то чем gRPC не является (gRPC не несёт реализацию).

---

## Что это даёт для бизнес-модели

ACT Cloud тогда — это не просто "хостинг agent tools", а **универсальная платформа для деплоя wasm компонентов с типизированным RPC**. Значительно больший рынок.

```
Agent tools    ← текущий фокус, точка входа
Микросервисы   ← следующий рынок
Edge functions ← естественное расширение
Плагины        ← встраиваемые компоненты в чужие приложения
```

---

## Риск расширения

Делать всё сразу — значит не сделать ничего хорошо. Tool-provider как первый стандартный интерфейс — правильная точка входа. Но архитектуру стоит проектировать так чтобы `tool-provider` был одним из многих возможных интерфейсов, а не hardcoded единственным.

Это влияет на одно решение прямо сейчас — **world должен быть расширяемым**:

```wit
// Не так — жёстко
world tools-world {
  export component-metadata;
  export tool-provider;
}

// А так — tool-provider как опциональный стандартный интерфейс
world act-world {
  export component-metadata;  // обязательно для всех
  import act:host/capabilities; // хост предоставляет
  // остальные интерфейсы — на усмотрение компонента
}
```

Стоит зафиксировать это в спеке уже сейчас, пока не поздно?



## Prompt:
3/5/2026, 1:03:06 AM

Не, я имею в виду другое: tools как концепция очень абстрактный и ничем по сути не ограничивается. А мы ещё и описываем паттерны взаимодействия с ним. То есть, это само по себе RPC



## Response:
3/5/2026, 1:03:19 AM

Да, точно. Ты прав — мы уже описали RPC, просто назвали его иначе.

Смотри что у нас есть:

```
call-tool(name, arguments) -> stream<result>
```

Это и есть RPC вызов. `name` — имя процедуры, `arguments` — параметры, `stream<result>` — ответ. `list-tools` — это рефлексия, то есть самодокументирование. `tool-annotations` с описаниями, типами параметров, примерами — это IDL.

Разница с классическим RPC только в том, что мы не генерируем строго типизированные stub'ы под каждую процедуру — вместо этого `arguments` это `list<tuple<string, string>>`. Но это сознательный выбор для гибкости, а не ограничение протокола.

---

## Что это означает концептуально

MCP называет это "tools" чтобы было понятно агентам. Но технически — это динамический RPC с самоописанием. И наш стандарт это тоже динамический RPC, просто с:

- Sandbox изоляцией (wasm)
- Stateful сессиями
- Streaming из коробки
- Локализованной документацией прямо в протоколе
- Capability декларацией

То есть позиционирование может быть честным:

```
ACT — это самодокументируемый RPC протокол
      поверх WebAssembly Component Model,
      оптимизированный для агентных систем
```

"Оптимизированный для агентов" — это про метадату, локализацию, usage-hints. Но архитектурно это просто хороший RPC.

---

Это кстати сильный аргумент в пользу того что стандарт шире чем MCP-замена. Хочешь зафиксировать это в описании спеки и двигаться к коду?



## Prompt:
3/5/2026, 1:05:18 AM

Как описать аргументы для tool?



## Response:
3/5/2026, 1:05:40 AM

Сейчас у нас `list<tuple<string, string>>` — это слабо. Давай разберём варианты.

---

## Проблема

Tool — это динамический RPC, но аргументы у нас untyped. Два противоречия:

```
WIT даёт строгую типизацию
    ↕  противоречие
Аргументы tools — динамические (имя известно только в runtime)
```

Потому что `call-tool` принимает имя инструмента как строку — мы не можем статически знать какие аргументы у `search_web` vs `send_email` на уровне WIT типов.

---

## Варианты

**Вариант A: JSON строка (как MCP)**
```wit
record tool-call {
  id: string,
  name: string,
  arguments: string,  // JSON object
  extensions: list<tuple<string, string>>,
}
```
Просто, универсально, все умеют JSON. Теряем типизацию полностью.

---

**Вариант B: Структурированное дерево значений**
```wit
variant value {
  null,
  bool(bool),
  integer(s64),
  float(f64),
  string(string),
  array(list<value>),
  object(list<tuple<string, value>>),
}

record tool-call {
  id: string,
  name: string,
  arguments: list<tuple<string, value>>,
  extensions: list<tuple<string, string>>,
}
```
Типизированное дерево без схемы. Аналог JSON но в WIT типах. Нет рекурсии в WIT — нужен `handle` или обходной путь.

Проблема: **WIT не поддерживает рекурсивные типы** напрямую.

---

**Вариант C: JSON Schema в метадате + JSON в runtime**
```wit
record parameter-meta {
  name: string,
  description: localized-string,
  // JSON Schema описывает тип параметра
  schema: string,
  required: bool,
  extensions: list<tuple<string, string>>,
}

record tool-call {
  id: string,
  name: string,
  // валидируется против schema из parameter-meta
  arguments: string,  // JSON
  extensions: list<tuple<string, string>>,
}
```
Схема известна заранее через `list-tools`, runtime передаёт JSON. Хост может валидировать до вызова.

---

**Вариант D: Бинарный encoded value (CBOR/MessagePack)**
```wit
record tool-call {
  id: string,
  name: string,
  arguments: list<u8>,  // CBOR encoded
  encoding: string,     // "cbor", "msgpack", "json"
  extensions: list<tuple<string, string>>,
}
```
Эффективно, но добавляет сложность на обоих концах.

---

## Моя рекомендация

**C** — JSON Schema в метадате, JSON в аргументах. Причины:

- JSON Schema уже понимают LLM агенты (MCP совместимость)
- Хост может валидировать аргументы **до** передачи в компонент
- Разработчик SDK пишет макрос который генерирует JSON Schema из Rust типов автоматически
- Расширяемо — в будущем можно добавить бинарный encoding через `extensions`

```
Разработчик пишет:     fn search(query: String, limit: u32)
SDK генерирует:        JSON Schema { query: string, limit: integer }
Агент получает:        схему через list-tools
Агент вызывает:        arguments: {"query": "rust", "limit": 10}
Хост валидирует:       против схемы перед вызовом
Компонент получает:    уже валидные данные
```

Что думаешь?



## Prompt:
3/5/2026, 1:08:53 AM

А если мы просто опишем tools как wit-функции, это будет не ок?



## Response:
3/5/2026, 1:09:10 AM

Это было бы идеально, но упирается в одну проблему.

---

## Почему это красиво

```wit
interface my-tools {
  search-web: async func(query: string, limit: u32) -> stream<search-result>;
  send-email: async func(to: string, subject: string, body: string) -> result<unit, string>;
}

world act-world {
  export component-metadata;
  export my-tools;
}
```

Полная типизация, никакого JSON, WIT генерирует биндинги для любого языка, хост знает сигнатуры статически. Это и есть настоящий типизированный RPC.

---

## Проблема: динамическое обнаружение

Агент не знает заранее какие функции экспортирует компонент. MCP-адаптер должен в runtime спросить "что ты умеешь?" и получить список с описаниями.

С статическими WIT экспортами это невозможно — хост должен знать интерфейс **до** загрузки компонента чтобы слинковать его.

```
Статический путь (разработчик приложения):
  знает WIT заранее → генерирует биндинги → компилирует → всё типизировано ✓

Динамический путь (агент / MCP адаптер):
  загружает неизвестный компонент → ??? → как узнать что внутри?
```

---

## Решение: два интерфейса в одном компоненте

```wit
world act-world {
  // Для агентов — динамическое обнаружение
  export component-metadata;
  export tool-provider;      // list-tools + call-tool с JSON Schema

  // Для приложений — статически типизированный интерфейс
  export my-tools;           // конкретные функции с WIT типами
}
```

Компонент экспортирует **оба**. Приложение которое знает WIT использует `my-tools` напрямую — полная типизация, нет JSON overhead. Агент который не знает WIT использует `tool-provider` — динамическое обнаружение через JSON Schema.

`tool-provider` в этом случае генерируется **автоматически из WIT** через SDK макрос:

```rust
#[act_tools]  // макрос читает сигнатуры и генерирует tool-provider реализацию
impl MyTools {
  async fn search_web(query: String, limit: u32) -> Vec<SearchResult> { ... }
}
```

Разработчик пишет только типизированные функции — всё остальное генерируется.

---

## Это меняет архитектуру спеки

```
WIT функции         = источник истины
    ↓ генерация
tool-provider       = динамический фасад для агентов
JSON Schema         = производное от WIT типов, не наоборот
```

Это значительно чище чем то что было. Фиксируем?



## Prompt:
3/5/2026, 1:11:06 AM

Кажется, это сильно усложняет sdk под каждый язык



## Response:
3/5/2026, 1:11:16 AM

Да, точно. Макрос который читает WIT типы и генерирует два интерфейса одновременно — это нетривиальная задача для каждого языка.

---

## Суть проблемы

```
Rust    → proc macro, сложно но реально
Python  → нет статических типов, очень сложно
Go      → кодогенерация, отдельный инструмент
JS/TS   → реально через декораторы
```

Каждый SDK становится большим самостоятельным проектом.

---

## Более простой подход

Оставить `tool-provider` как единственный интерфейс, но улучшить описание аргументов через JSON Schema в метадате. Тогда SDK в любом языке — это просто:

```
1. Зарегистрировать функцию с именем и схемой
2. Реализовать list-tools (вернуть зарегистрированные)
3. Реализовать call-tool (задиспатчить по имени)
```

Это тривиально на любом языке. Статическая типизация остаётся на уровне конкретного языка внутри компонента — разработчик пишет типизированный Rust/Python код, а наружу торчит универсальный `tool-provider`.

---

## Вывод

Две версии интерфейса — красивая идея, но преждевременная оптимизация. Adoption важнее элегантности на старте. Возвращаемся к варианту C (JSON Schema в метадате)?



## Prompt:
3/5/2026, 1:11:39 AM

Да



## Response:
3/5/2026, 1:11:46 AM

Фиксируем. Обновляем `parameter-meta`:

```wit
record parameter-meta {
  name: string,
  description: localized-string,
  schema: string,              // JSON Schema для этого параметра
  required: bool,
  extensions: list<tuple<string, string>>,
}
```

И `tool-call` — аргументы как JSON объект:

```wit
record tool-call {
  id: string,
  name: string,
  arguments: string,           // JSON object, валидируется против schema
  extensions: list<tuple<string, string>>,
}
```

---

## Что это даёт

```
Разработчик   → описывает параметры через SDK макрос
SDK           → генерирует JSON Schema из типов языка
Агент         → получает схему через list-tools, формирует JSON
Хост          → валидирует arguments против schema до вызова компонента
Компонент     → получает уже валидный JSON, десериализует в нативные типы
```

Валидация на стороне хоста — важная деталь. Компонент не тратит wasm-циклы на проверку входных данных, это забота хоста.

---

Спека теперь полная и консистентная. Готов скаффолдить репозиторий и host-крейт?



## Prompt:
3/5/2026, 1:12:13 AM

В рамках этой сессии мы занимаемся только концепцией и спецификацией, не кодом



## Response:
3/5/2026, 1:12:24 AM

Понял, фиксирую.

Тогда подведём итог — что у нас есть на уровне концепции и спецификации:

---

## ACT — Agent Component Tools

**Суть:** самодокументируемый RPC протокол поверх WebAssembly Component Model, оптимизированный для агентных систем.

**Ключевые решения:**

- WIT как единственный IDL, JSON Schema генерируется из него
- Stateful сессии через resource handles
- Streaming результатов (`stream<stream-event>`) с двухуровневыми ошибками
- Локализованные строки (`localized-string`) везде где текст для агента
- Расширяемость через `extensions` на всех record'ах + версионирование пакетов
- Capabilities как открытый реестр URI, заполняются хостом из анализа wasm импортов
- MCP как один из транспортов, не архитектурная основа
- Cancellation через дроп stream handle

**Экосистема:**
- Component Host (Rust lib) — ядро
- CLI, Unified Server (MCP + RPC), SDK per язык
- ACT Cloud, Registry, Enterprise, Консалтинг — бизнес-модель

---

Что хочешь проработать дальше в рамках концепции? Например, спека capability negotiation, модель версионирования, или что-то ещё?





---
Powered by [Claude Exporter](https://www.ai-chat-exporter.net)