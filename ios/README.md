# ZWords para iPhone

Legendas ao vivo de qualquer inglês que você ouve, com **toque único para salvar palavras** no seu vocabulário — tudo processado no próprio iPhone, de graça e offline.

```
ouvir  →  ler a legenda  →  tocar na palavra  →  salva com a frase, o significado e a tradução
```

## O que o app faz

| Recurso | Como funciona | Tecnologia (gratuita, no aparelho) |
|---|---|---|
| Áudio do microfone | Conversas, aulas, palestras, som ambiente (inclusive o alto-falante do próprio iPhone) | `AVAudioEngine` |
| Áudio interno do iPhone | Vídeos, podcasts, redes sociais, navegador e outros apps, enquanto você usa esses apps | Extensão de transmissão ReplayKit (`RPBroadcastSampleHandler`, áudio `.audioApp`) |
| Transcrição em tempo real | Palavra por palavra, sem resumir nem reescrever; as legendas fecham a cada pausa, como em filmes | `SFSpeechRecognizer` com `requiresOnDeviceRecognition` |
| Tradução simultânea | Por frase inteira (com contexto, não palavra a palavra); modos **EN**, **PT** e **EN + PT** alternáveis a qualquer momento | Framework Translation da Apple (en → pt‑BR) |
| Legendas sobre outros apps | Janela flutuante com a legenda atual | Picture in Picture (`AVSampleBufferDisplayLayer`) |
| Toque para salvar | Um toque, sem confirmação; vibração leve e destaque das palavras já salvas | SwiftUI |
| Significado no contexto | Ex.: *bank* em "river bank" → "margem do rio" | Apple Intelligence on-device (`FoundationModels`, iOS 26) ou, sem ela, tradução da forma de dicionário + classe gramatical |
| Sem duplicatas | *ran*, *running* e *runs* entram em **run**; um contexto novo é anexado à palavra existente | `NaturalLanguage` (lematização) |
| Biblioteca | Busca por palavra, frase ou significado; todos os contextos reais; pronúncia; revisão espaçada | SwiftData + `AVSpeechSynthesizer` |

Uma tela só: escolha o modo de legenda no topo, toque em **Microfone**, **iPhone** ou **Flutuante** embaixo, e abra a biblioteca pelo ícone de livros.

## Limitações do iOS (e as alternativas adotadas)

- **Áudio de outros apps**: o iOS não permite que um app ouça outros apps diretamente. A única via pública é uma *transmissão de tela* (ReplayKit), que entrega o áudio do sistema. Por isso, ao tocar em **iPhone** aparece a tela da Apple "Iniciar Transmissão" e o indicador vermelho fica visível enquanto ela durar. O vídeo da tela é descartado imediatamente; nada sai do aparelho.
- **Chamadas telefônicas e FaceTime**: o iOS bloqueia a captura do áudio de chamadas por qualquer app de terceiros (nem a transmissão nem o microfone recebem a voz do outro lado). A alternativa gratuita mais próxima é a **gravação e transcrição nativa de chamadas do app Telefone** (iOS 18.1+: botão de gravação durante a chamada; a transcrição fica no app Notas). Para chamadas em viva-voz, o modo **Microfone** capta parte do áudio, com qualidade menor.
- **Apps protegidos (DRM)**: alguns apps (por exemplo, certos serviços de streaming) silenciam o áudio durante a transmissão de tela. Nesses casos, use o modo **Microfone** com o som no alto-falante.
- **Sobreposição de legendas**: o iOS não permite janelas por cima de outros apps; a legenda flutuante usa o Picture in Picture, a única forma permitida. Dentro do PiP não dá para tocar nas palavras: as frases ficam guardadas na tela principal, e basta voltar ao ZWords para tocar nelas.
- **Execução em segundo plano**: o microfone continua funcionando em segundo plano (modo de áudio). No modo iPhone, o app mantém uma sessão de áudio silenciosa e misturável para as legendas flutuantes não congelarem.
- **Idiomas da tradução**: na primeira vez, o iOS pede para baixar os pacotes Inglês e Português (gratuito, uma vez só). Depois a tradução funciona offline.
- **Significado com Apple Intelligence** exige iOS 26 em um iPhone compatível (15 Pro ou mais novo) com a Apple Intelligence ativada. Nos outros aparelhos, o app usa a tradução da forma de dicionário com a classe gramatical (ex.: "correr (verbo)").
- **Transcrição offline** exige um iPhone com suporte a ditado no aparelho (iPhone XS/XR ou mais novo). Sem isso, a Apple processa o áudio on-line, também de graça.
- Requer **iOS 18** ou mais recente.

## Instalação gratuita

A Apple só permite instalar apps fora da App Store assinados com um Apple ID. Com um **Apple ID gratuito**:

- a instalação vale por **7 dias** e precisa ser renovada (sem perder o vocabulário);
- são no máximo 3 apps instalados por esse método ao mesmo tempo, e 10 "App IDs" por semana (o ZWords usa 2: o app e a extensão).

O Apple Developer Program (US$ 99/ano) elimina o limite de 7 dias, mas é opcional.

Antes de abrir o app pela primeira vez, ative o **Modo de Desenvolvedor** em Ajustes › Privacidade e Segurança. Depois confie no perfil em Ajustes › Geral › VPN e Gerenciamento de Dispositivos.

### Opção A — Com um Mac e Xcode (mais simples, mais confiável)

1. Instale o Xcode (gratuito, na Mac App Store) e o XcodeGen: `brew install xcodegen`.
2. Em `ios/Config/Signing.xcconfig`, troque `ZW_BUNDLE_PREFIX` por algo único, como `com.seunome.zwords`.
3. No Terminal: `cd ios && xcodegen generate && open ZWords.xcodeproj`.
4. Em Xcode › Settings › Accounts, adicione o seu Apple ID. No projeto, em *Signing & Capabilities*, escolha o seu "Personal Team" nos alvos **ZWords** e **ZWordsBroadcast**.
5. Conecte o iPhone por cabo, selecione-o como destino e clique em ▶︎ Run.
6. Para renovar a cada 7 dias, basta repetir o passo 5.

### Opção B — Sem Mac: IPA + SideStore/AltStore (renovação automática)

O GitHub Actions compila o app em macOS a cada alteração e publica o arquivo **`ZWords.ipa`** na release **`ios-latest`** do repositório (também disponível como artefato da execução).

1. Instale o **SideStore** (sidestore.io) ou o **AltStore** (altstore.io). É gratuito e exige um computador Windows/Mac/Linux uma única vez.
2. Baixe o `ZWords.ipa` no iPhone (aba *Releases* do GitHub, ou pelo computador e depois pelo app Arquivos).
3. No SideStore/AltStore: **My Apps › +** e escolha o `ZWords.ipa`.
4. O SideStore renova a assinatura sozinho em segundo plano antes dos 7 dias; o AltStore renova quando o AltServer está na mesma rede Wi‑Fi.

> O Sideloadly (Windows/Mac) também instala o mesmo `.ipa` com um Apple ID gratuito.

## Primeiro uso

1. Abra o ZWords e permita o **Reconhecimento de Fala** (necessário também para o modo iPhone).
2. Aceite o download dos idiomas da tradução quando o iOS pedir.
3. **Microfone**: toque no botão central. **Áudio do iPhone**: toque em *iPhone*, depois em *Iniciar Transmissão*, e abra o app de vídeo ou podcast. Para parar, toque de novo em *iPhone* ou no indicador vermelho.
4. Toque em **Flutuante** (ou simplesmente vá para a tela inicial) para manter a legenda sobre outros apps.
5. Toque em qualquer palavra em inglês: ela vai para a biblioteca com a frase, o significado e a tradução.

## Desenvolvimento

```
ios/
├── project.yml              # projeto Xcode (XcodeGen)
├── Config/Signing.xcconfig  # bundle ID / time de assinatura
├── Shared/                  # usado pelo app e pela extensão
│   ├── LiveTranscriber.swift      # fala → texto contínuo, segmentado por pausas
│   ├── SampleBufferAudio.swift    # áudio do ReplayKit (big-endian/int16) → PCM float
│   └── BroadcastChannel.swift     # App Group + notificações Darwin
├── ZWords/                  # app SwiftUI
│   ├── Captions/   motor de legendas e tokenização
│   ├── Capture/    microfone, sessão de áudio, receptor da transmissão
│   ├── Translation/ tradução (Translation) e significado (FoundationModels)
│   ├── Vocabulary/ SwiftData, lematização, revisão espaçada
│   ├── PiP/        legenda flutuante
│   └── UI/         tela única, biblioteca e revisão
├── ZWordsBroadcast/         # extensão de transmissão (áudio de todos os apps)
└── ZWordsTests/             # testes unitários
```

Testes: `xcodebuild test -project ZWords.xcodeproj -scheme ZWords -destination 'platform=iOS Simulator,name=iPhone 16'`.

O CI (`.github/workflows/ios.yml`) gera o projeto, roda os testes no simulador, compila para o dispositivo e empacota o IPA.

Dependências externas, assinaturas ou APIs pagas: **nenhuma**.
