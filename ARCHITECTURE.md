# V3 Titan — Arquitetura do Sistema

> Documento técnico de referência para a stack Rust (cdylib) + C# WPF via FFI/P/Invoke.

---

## 1. Diagrama de Fluxo de Dados

```
┌─────────────────────────────────────────────────────────────┐
│                    KERNEL SPACE                             │
│                                                             │
│   NIC (placa de rede) ──► Npcap Driver (npcap.sys)         │
│                               │ modo promíscuo              │
│                               │ filtro BPF aplicado aqui    │
└───────────────────────────────┼─────────────────────────────┘
                                │ syscall / IOCTL
┌───────────────────────────────▼─────────────────────────────┐
│                    USER SPACE                               │
│                                                             │
│   ┌─────────────────────────────────────────────────────┐   │
│   │              Rust — sniffer.dll (cdylib)            │   │
│   │                                                     │   │
│   │  pcap::Capture::next_packet()                       │   │
│   │       │                                             │   │
│   │       ▼                                             │   │
│   │  parse_packet()  →  PacketInfo { #[repr(C)] }       │   │
│   │       │                                             │   │
│   │       ▼                                             │   │
│   │  (callback_fn)(*const PacketInfo)  ◄── registrado  │   │
│   │       │                  pelo C#                    │   │
│   └───────┼─────────────────────────────────────────────┘   │
│           │  FFI boundary (C ABI)                           │
│   ┌───────▼─────────────────────────────────────────────┐   │
│   │              C# WPF — TitanUI.exe                   │   │
│   │                                                     │   │
│   │  PacketCallback (delegate, GCHandle pinado)         │   │
│   │       │                                             │   │
│   │       ▼                                             │   │
│   │  Dispatcher.BeginInvoke(UI thread)                  │   │
│   │       │                                             │   │
│   │       ▼                                             │   │
│   │  ObservableCollection / DataGrid                    │   │
│   └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Como o FFI Funciona: Memória Não-Gerenciada → Gerenciada

### 2.1 O Problema de Fronteira

Rust e .NET têm modelos de memória incompatíveis:

| Aspecto | Rust | C# (.NET) |
|---|---|---|
| Gestão de memória | Ownership / borrow checker | Garbage Collector (GC) |
| Layout de struct | Otimizado pelo compilador | Controlado pelo CLR |
| Strings | UTF-8 (`&str`, `String`) | UTF-16 (`System.String`) |
| Ponteiros de função | `fn` pointer (estático) | delegate (objeto gerenciado) |

### 2.2 Regras Obrigatórias da Fronteira

**No Rust — exportar com C ABI:**
```rust
// Struct com layout de memória previsível para o C#
#[repr(C)]
pub struct PacketInfo {
    pub src_ip:   [u8; 4],
    pub dst_ip:   [u8; 4],
    pub src_port: u16,
    pub dst_port: u16,
    pub protocol: u8,
    pub length:   u32,
}

// Tipo do callback registrado pelo C#
pub type PacketCallback = extern "C" fn(*const PacketInfo);

// Função exportada — visível via P/Invoke
#[no_mangle]
pub extern "C" fn registrar_callback(cb: PacketCallback) { ... }

#[no_mangle]
pub extern "C" fn iniciar_captura(interface: *const i8, filtro: *const i8) { ... }

#[no_mangle]
pub extern "C" fn parar_captura() { ... }
```

**No C# — importar via P/Invoke:**
```csharp
// Struct com layout idêntico ao Rust
[StructLayout(LayoutKind.Sequential)]
public struct PacketInfo
{
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 4)]
    public byte[] SrcIp;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 4)]
    public byte[] DstIp;
    public ushort SrcPort;
    public ushort DstPort;
    public byte   Protocol;
    public uint   Length;
}

// Delegate que corresponde ao fn pointer do Rust
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate void PacketCallback(IntPtr packetPtr);

// Importações
[DllImport("sniffer.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern void registrar_callback(PacketCallback cb);

[DllImport("sniffer.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern void iniciar_captura(string iface, string filtro);

[DllImport("sniffer.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern void parar_captura();
```

### 2.3 Pinagem do Delegate — Ponto Crítico

O GC do .NET pode mover objetos na memória a qualquer momento. Se o Rust guardar um ponteiro para o delegate e o GC o mover, o programa crasha.

**Solução obrigatória:**
```csharp
private PacketCallback _callback;   // campo — impede coleta pelo GC
private GCHandle       _gcHandle;   // pina o objeto em memória fixa

public void Inicializar()
{
    _callback = OnPacketRecebido;
    _gcHandle = GCHandle.Alloc(_callback, GCHandleType.Normal);
    registrar_callback(_callback);
}

public void Encerrar()
{
    parar_captura();
    _gcHandle.Free();  // libera após o Rust ter parado
}
```

---

## 3. Ciclo de Vida do Motor de Captura

```
INICIALIZAÇÃO
─────────────────────────────────────────────────────
  C# chama: registrar_callback(fn_ptr)
  C# chama: iniciar_captura("eth0", "tcp")

      Rust:
        1. Cria AtomicBool flag_parar = false
        2. pcap::Device::lookup(interface)
        3. Capture::from_device(device)
               .promisc(true)
               .snaplen(65535)
               .open()
        4. capture.filter(filtro_bpf)
        5. std::thread::spawn(|| loop_captura())

LOOP DE CAPTURA (thread dedicada no Rust)
─────────────────────────────────────────────────────
  loop {
      if flag_parar.load(Ordering::Relaxed) { break; }

      match capture.next_packet() {
          Ok(packet) => {
              let info = parse_packet(packet);
              (callback)(&info);           // chama o C#
          }
          Err(TimeoutExpired) => continue,
          Err(e) => { log_erro(e); break; }
      }
  }

ENCERRAMENTO SEGURO
─────────────────────────────────────────────────────
  C# chama: parar_captura()

      Rust:
        1. flag_parar.store(true, Ordering::Relaxed)
        2. thread.join()         ← aguarda o loop terminar
        3. drop(capture)         ← pcap_close() automático

  C#:
        4. _gcHandle.Free()      ← só após o Rust ter parado
```

---

## 4. Estratégia para o Bloqueio da UI Thread (WPF)

Este é o ponto crítico de estabilidade da aplicação.

### 4.1 O Problema

O callback do Rust é executado numa **thread nativa** (não é a UI thread do WPF). Qualquer acesso direto a controlos WPF a partir desta thread causa `InvalidOperationException`.

```
Thread do Rust ──► callback ──► ListView.Items.Add(...)  💥 CRASH
```

### 4.2 A Solução: Dispatcher + Canal de Dados

**Padrão correto — duas camadas de proteção:**

```csharp
// Camada 1: canal thread-safe entre Rust e C#
private readonly Channel<PacketInfo> _canal =
    Channel.CreateBounded<PacketInfo>(new BoundedChannelOptions(1000)
    {
        FullMode = BoundedChannelFullMode.DropOldest  // descarta se a UI não acompanhar
    });

// Camada 2: o callback apenas enfileira — nunca toca na UI
private void OnPacketRecebido(IntPtr ptr)
{
    var info = Marshal.PtrToStructure<PacketInfo>(ptr);
    _canal.Writer.TryWrite(info);   // não bloqueia, não trava o Rust
}

// Camada 3: loop assíncrono na UI thread consome o canal
private async Task ProcessarPacotesAsync(CancellationToken ct)
{
    await foreach (var info in _canal.Reader.ReadAllAsync(ct))
    {
        // Já estamos na UI thread (await retorna ao contexto original)
        Pacotes.Add(new PacoteViewModel(info));

        // Limite de itens para não consumir memória infinita
        if (Pacotes.Count > 500)
            Pacotes.RemoveAt(0);
    }
}
```

**Inicialização no `MainWindow.xaml.cs`:**
```csharp
protected override void OnInitialized(EventArgs e)
{
    base.OnInitialized(e);
    var cts = new CancellationTokenSource();
    _ = ProcessarPacotesAsync(cts.Token);  // inicia o consumidor na UI thread
}
```

### 4.3 Por Que Este Padrão é Correto

| Elemento | Responsabilidade |
|---|---|
| `Channel<T>` | Fila thread-safe de alta performance (sem lock) |
| `TryWrite` no callback | Não bloqueia — o Rust nunca espera pela UI |
| `BoundedChannelFullMode.DropOldest` | Evita consumo ilimitado de memória sob carga |
| `await foreach` na UI thread | Processa pacotes sem bloquear a interface |
| `CancellationToken` | Encerramento limpo ao fechar a janela |

---

## 5. Estrutura de Pastas

```
v3_titan/                         ← repositório principal
├── ARCHITECTURE.md               ← este documento
├── README.md
├── .gitignore
├── .gitmodules
└── TitanUI/                      ← submodule (github.com/jeremiasmarinho/TitanUI)
    ├── TitanUI.slnx              ← solução Visual Studio
    ├── sniffer-core/             ← [Fase 1] biblioteca Rust
    │   ├── Cargo.toml
    │   ├── build.rs
    │   └── src/
    │       └── lib.rs
    └── TitanUI/                  ← projeto C# WPF
        ├── TitanUI.csproj
        ├── App.xaml
        ├── App.xaml.cs
        ├── MainWindow.xaml
        ├── MainWindow.xaml.cs
        └── Interop/
            └── SnifferInterop.cs
```

---

## 6. Referências

| Recurso | Descrição |
|---|---|
| [crate pcap](https://docs.rs/pcap) | Abstração Rust para libpcap/Npcap |
| [Npcap SDK](https://npcap.com) | Headers e .lib para Windows |
| [System.Threading.Channels](https://learn.microsoft.com/dotnet/core/extensions/channels) | Canal thread-safe no .NET |
| [P/Invoke no .NET](https://learn.microsoft.com/dotnet/standard/native-interop/pinvoke) | Interop C# ↔ nativo |
| [Rust FFI Omnibus](https://jakegoulding.com/rust-ffi-omnibus/) | Padrões FFI Rust ↔ outras linguagens |
