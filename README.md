# Cowboy Rec iOS — instalação pessoal gratuita

Aplicativo independente do gravador web e do projeto de óculos Meta. Câmera nativa AVFoundation, 4K/60 quando disponível no formato; não reduz resolução/fps para conseguir estabilização. Rampa nativa de zoom, preview AVFoundation, captura HEVC quando suportada. Exposição e balanço de branco podem ser travados pelo usuário. Não aplica CSS, canvas ou uma segunda estabilização no servidor.

Perfil inicial Forte solicita cinematicExtended e mostra os modos solicitado/ativo. Esse modo não foi comprovado equivalente ao Extreme da Blackmagic. Fallback explícito para Cinematic/Standard conforme suporte do formato, preservando 4K/60. Modos mais fortes podem adicionar atraso e recorte. Mudança de lente fica sob controle do dispositivo virtual iOS; não foi implementada calibração extra de paralaxe/cor. Retrato somente nesta versão.

Gravação local primeiro; envia ao parar, pela conta Cowboy, em partes de 8 MB com recibos. Não é streaming ao vivo nem upload durante a captura. Limite de 256 MB por clipe; o sistema finaliza ao atingir o limite. Interrupções de segundo plano encerram captura. Fila persistente vinculada à conta; Retomar confere conta e continua pelos recibos. Original preservado, convert:none, estabilização do servidor desativada. Se enfileirar falha, captura permanece em Application Support e a tela oferece compartilhar o arquivo. Capturas finalizadas que ficaram fora da fila são recuperadas ao entrar na mesma conta. Capturas danificadas por encerramento forçado são preservadas para exportação e recuperação manual; não há promessa de reparo automático.

## Compilar

Mac/Xcode: instalar XcodeGen oficial, executar `xcodegen generate`, abrir CowboyRec.xcodeproj e compilar CowboyRec. Conta Apple gratuita serve para instalação pessoal com renovação semanal. Outra opção é o workflow manual incluído: runner macOS, build sem assinatura, IPA para assinatura local. Repositório público usa runners padrão gratuitos. Em repositório privado, conferir a cota antes de disparar; não executar se puder gerar cobrança. O workflow tem timeout de 20 minutos e artefato expira em 3 dias.

## Instalar pelo Windows

Instalar AltServer/AltStore Classic seguindo o fornecedor. Apple ID deve ser informado diretamente pelo usuário ao AltServer, não no chat ou GitHub. Habilitar Developer Mode no iPhone e assinar/importar o IPA com AltStore. Conta gratuita exige renovar antes de 7 dias; AltStore pode renovar quando AltServer está acessível. O IPA sem assinatura não instala por um link do Safari. Não requer Apple Developer pago para uso pessoal; não oferece distribuição permanente pela App Store/TestFlight.

## Validação pendente

Compilação inicial Release/arm64 realizada com sucesso no runner macOS do GitHub em 04/10/2026. Compilação final Release/arm64 concluída com sucesso e IPA verificado: ZIP íntegro, binário ARM64 de iPhone, identificador correto e permissões de câmera/microfone. Build: https://github.com/Thyayro/cowboy-rec-ios/actions/runs/37218309137 . Instalação, assinatura e testes físicos no iPhone 16 ainda pendentes. Não anunciar como instalado ou funcionando no iPhone antes de build, assinatura e teste. Conferir prévia/arquivo no iPhone 16 em 0,5x, 1x, 2x, 5x e 10x; modos Standard/Cinematic/Forte, latência, cor/luz, fps/resolução reais, áudio, interrupção e retomada dos envios. Calibrar contra Blackmagic Extreme no mesmo cenário. Não há garantia de troca de lente imperceptível.

Fontes: https://developer.apple.com/support/compare-memberships/ ; https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows ; https://faq.altstore.io/altstore-classic/your-altstore ; https://docs.github.com/en/actions/concepts/billing-and-usage ; https://developer.apple.com/documentation/avfoundation/avcapturevideostabilizationmode/cinematicextended


## Backup e retorno

A versão anterior está na tag `backup/pre-final-20261004` e no arquivo local `.backups/cowboy-rec-ios-before-final-20261004.zip` do workspace de origem. A primeira compilação também foi preservada em `.backups/cowboy-rec-ios-first-build`. O gravador web permanece publicado, separado deste aplicativo; seus fontes foram arquivados na VPS em `/root/cowboy-rec-web-before-native-20261004.tar.gz`. Nenhum serviço web foi reiniciado ou substituído nesta etapa. Para usar o gravador anterior, abra o endereço `/rec` no Safari. Para retornar ao código nativo anterior, use a tag de backup e compile novamente; os arquivos pendentes no iPhone não devem ser apagados.


## Versão de teste publicada

Download: https://github.com/Thyayro/cowboy-rec-ios/releases/tag/v0.1.0-test

O arquivo CowboyRec-unsigned.ipa deve ser assinado/importado com AltStore Classic; o Safari não instala diretamente. Depois da instalação: entre em Conta / biblioteca, volte à câmera, confira o modo solicitado/ativo e grave um clipe curto. Verifique o vídeo na biblioteca antes de gravações importantes. A versão web anterior continua disponível.

SHA256 do IPA: `02780c0471c6966ba87c5f5ac07b879e3cb1f36bda22c8780070110c752ca167`.
## v0.2.0 — câmera ampla e Rec integrado

A câmera nativa ocupa a tela, com zoom e gravação sobre a prévia. Biblioteca e Rec completo abrem as telas reais da VPS dentro do aplicativo, compartilhando o cookie persistente de login com os envios nativos. O primeiro acesso sem conta abre o login automaticamente. Downloads da biblioteca podem ser exportados pelo compartilhamento do iOS. O app impede voltar à câmera nativa enquanto o Rec web está gravando.

A captura nativa usa AVFoundation; as funções adicionais do Rec continuam sendo executadas pela interface web, não foram reimplementadas como controles AVFoundation. Ao entrar no Rec completo, a câmera nativa é liberada para evitar disputa com a câmera web. A prévia preenche a tela com resizeAspectFill; o vídeo salvo conserva o quadro original. Capturas nativas mantêm o limite de 256 MB e o envio ao parar.

Atualização: baixe o IPA v0.2.0 e importe com + no AltStore, mantendo o app instalado. O bundle identifier permanece com.cowboy.rec.personal, para atualização no mesmo app e preservação da fila. Backup do código anterior: backup/native-ui-v0.1.0-20261004. Os dados continuam nas APIs e arquivos de sessões existentes da VPS; nenhum banco alternativo foi criado.

Validação: compilação Release para iPhone, integridade do IPA e acesso HTTP autenticado a /api/me, /api/rec/list, /rec e /js/rec/rec.js. Login interativo, permissões WebKit, layout físico, downloads e captura/envio no iPhone devem ser conferidos no dispositivo; testes de servidor não comprovam o fluxo físico.

## v0.3.0 — formatos e controles nativos

O padrão da câmera nativa passa a ser a câmera traseira principal física (builtInWideAngleCamera), em 3840×2160 a 60 fps. A sessão permanece inputPriority; não escolhe resolução/FPS inferiores para satisfazer estabilização. A lista de lentes vem da descoberta AVFoundation e a lista de perfis vem dos formatos/frame-rate ranges de cada dispositivo. Oferece taxas usuais e limites detectados, incluindo taxas elevadas apenas nas resoluções que as suportam. A disponibilidade exata deve ser conferida no aparelho.

Novos controles: seleção de lente (principal, ultra-angular, teleobjetiva, traseira virtual e frontal quando presentes), resolução/FPS, HDR HLG quando o formato anuncia suporte, HEVC/H.264 anunciados pelo movie output, foco por toque e foco manual, ISO/obturador manuais, compensação de exposição, balanço de branco manual e lanterna. Os sliders são limitados aos valores válidos; o obturador não excede o período do frame. Não foram implementados modos de fotografia computacional, ProRes, Apple Log ou câmera lenta com montagem de velocidade na timeline. FPS elevados gravam o vídeo em sua taxa nativa; a mudança de velocidade permanece no editor.

Troca de formato, lente física, HDR e codec exige parar o vídeo. O preset 0,5× troca para a ultra-angular fora de gravação quando ela suporta o formato atual. Durante a gravação, o zoom fica dentro da lente selecionada; selecione a traseira automática antes de gravar para usar o dispositivo virtual. O app suporta retrato e paisagem e fixa o ângulo do vídeo ao iniciar a tomada. A prévia usa resizeAspectFill; o original conserva o quadro e a resolução selecionados. Dados de lente/formato/HDR/codec/estabilização e duração são enviados às APIs existentes da VPS.

A fila mantém compatibilidade com vídeos pendentes de versões anteriores. Backup: backup/native-v0.2.1-20261004. A captura nativa continua limitada a 256 MB por clipe com envio ao parar. Compilação Release e testes executados em Swift para seleção de formatos: impedir redução silenciosa de resolução/FPS/HDR, respeitar taxas fracionárias e preferir estabilização sem mudar a qualidade. O suporte real de cada lente, HDR, ISO, foco, lanterna, orientação e arquivo enviado precisam ser validados no iPhone físico.

## v0.5.0 — direto na nuvem, estabilização Extrema, 0,5× real, LUT na prévia, ferramentas na tela

**Grava DIRETO na VPS.** Saiu o `AVCaptureMovieFileOutput` (arquivo .mov inteiro no iPhone, envio só ao parar). Agora `AVCaptureVideoDataOutput` + `AVAssetWriter` no perfil `mpeg4AppleHLS` entregam o init e um fragmento MP4 por segundo em memória; cada um sobe na hora em `/api/rec/chunk` (mesma API do Rec web, com recibo e ordem). O iPhone só grava em disco o que a rede não acompanhou (fila acima de 96 MB, sem rede, app indo pro fundo) e apaga assim que o servidor confirma. Retomada: `CowboyStream/<cid>/take.json` + `NNNNNN.m4s`; se o app morrer gravando, o que estava só na memória se perde e o resto é renumerado e sobe (o MP4 fragmentado continua tocando). Sem limite de 256 MB por clipe. A VPS remonta (`-c copy +faststart`; testado init+fragmentos com `styp/sidx` concatenados), converte Apple Log → Rec.709 (`settings.color_profile = applelog`, `convert: keep`) e gera o reprodutor.

**Estabilização**: Desligada · Standard · Cinematic · Cinematic Extended · **Extrema** (`cinematicExtendedEnhanced`, iOS 18). Se o formato não tiver o modo, cai só pra modos mais fracos, nunca baixa resolução/fps. A prévia é o mesmo quadro estabilizado que vai pro arquivo.

**Lentes**: padrão = câmera virtual traseira (tripla no Pro: 0,5 · 1 · 2 · 5×). Zoom por `ramp(toVideoZoomFactor:withRate:)` com taxa em oitavas/s (velocidade constante atravessando as trocas de lente), pinça, e roda arrastando a barra de lentes. "Só a principal" continua nos ajustes.

**Cor**: Apple Log real (10 bits HEVC) quando o formato anuncia `.appleLog`. Prévia em Metal/Core Image com `CIColorCube` 33³ gerado da MESMA conta do `server/colorluts.js` (Log → Rec.709) e dos looks do `look.js` (Natural, Cowboy, Cinema, Vivo, Suave, Noite, P&B). "LOG cru" mostra o sinal sem LUT. Look ≠ Natural vai como `.cube` da tomada; o vídeo sai limpo.

**Ferramentas na lateral** (chaves independentes, como no web): Grade (terços/quadriculado), Nível (gravidade, amarelo a <1°), 3D (grade de 50 cm no chão presa pelo giroscópio, "Fixar chão", altura, ajuste de lente; AR 6DoF continua no modo ARKit), LUT, Moldura (Reels/Stories/Feed 4:5/Anúncio com zonas cobertas e área segura), Enquadrar (9:16, 4:5, 1:1, 16:9, 2,39, Livre). Rodapé sem degradê: biblioteca · obturador · virar.

**Junto de cada tomada**: `.gcsv` (Gyroflow, 100 Hz, eixos do iPhone), `.space.json` (altura, chão, zoom, FOV), miniatura JPEG já em Rec.709, `.cube` do look.

**Não testado em aparelho** (compilado no runner macOS, Xcode 16.4 / SDK iOS 18.5): orientação da prévia Metal, áudio+vídeo no mesmo escritor HLS, Extrema ativa em 4K60 Log na câmera virtual, latência e banda reais do envio. Conferir no iPhone antes de gravação importante. Backup da versão anterior: tag `backup/native-v0.4.0-20261007`.
