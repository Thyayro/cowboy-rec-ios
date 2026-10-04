# Cowboy Rec iOS — instalação pessoal gratuita

Aplicativo independente do gravador web e do projeto de óculos Meta. Câmera nativa AVFoundation, 4K/60 quando disponível no formato; não reduz resolução/fps para conseguir estabilização. Rampa nativa de zoom, preview AVFoundation, captura HEVC quando suportada. Exposição e balanço de branco podem ser travados pelo usuário. Não aplica CSS, canvas ou uma segunda estabilização no servidor.

Perfil inicial Forte solicita cinematicExtended e mostra os modos solicitado/ativo. Esse modo não foi comprovado equivalente ao Extreme da Blackmagic. Fallback explícito para Cinematic/Standard conforme suporte do formato, preservando 4K/60. Modos mais fortes podem adicionar atraso e recorte. Mudança de lente fica sob controle do dispositivo virtual iOS; não foi implementada calibração extra de paralaxe/cor. Retrato somente nesta versão.

Gravação local primeiro; envia ao parar, pela conta Cowboy, em partes de 8 MB com recibos. Não é streaming ao vivo nem upload durante a captura. Limite de 256 MB por clipe; o sistema finaliza ao atingir o limite. Interrupções de segundo plano encerram captura. Fila persistente vinculada à conta; Retomar confere conta e continua pelos recibos. Original preservado, convert:none, estabilização do servidor desativada. Se enfileirar falha, captura permanece em Application Support e a tela oferece compartilhar o arquivo. Capturas interrompidas por encerramento forçado ainda precisam de recuperação manual; não há promessa de reparo automático.

## Compilar

Mac/Xcode: instalar XcodeGen oficial, executar `xcodegen generate`, abrir CowboyRec.xcodeproj e compilar CowboyRec. Conta Apple gratuita serve para instalação pessoal com renovação semanal. Outra opção é o workflow manual incluído: runner macOS, build sem assinatura, IPA para assinatura local. Repositório público usa runners padrão gratuitos. Em repositório privado, conferir a cota antes de disparar; não executar se puder gerar cobrança. O workflow tem timeout de 20 minutos e artefato expira em 3 dias.

## Instalar pelo Windows

Instalar AltServer/AltStore Classic seguindo o fornecedor. Apple ID deve ser informado diretamente pelo usuário ao AltServer, não no chat ou GitHub. Habilitar Developer Mode no iPhone e assinar/importar o IPA com AltStore. Conta gratuita exige renovar antes de 7 dias; AltStore pode renovar quando AltServer está acessível. O IPA sem assinatura não instala por um link do Safari. Não requer Apple Developer pago para uso pessoal; não oferece distribuição permanente pela App Store/TestFlight.

## Validação pendente

Fonte preparada em Windows. Sem SDK iOS/Xcode local; compilação e testes físicos ainda pendentes. Não anunciar como instalado ou funcionando no iPhone antes de build, assinatura e teste. Conferir prévia/arquivo no iPhone 16 em 0,5x, 1x, 2x, 5x e 10x; modos Standard/Cinematic/Forte, latência, cor/luz, fps/resolução reais, áudio, interrupção e retomada dos envios. Calibrar contra Blackmagic Extreme no mesmo cenário. Não há garantia de troca de lente imperceptível.

Fontes: https://developer.apple.com/support/compare-memberships/ ; https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows ; https://faq.altstore.io/altstore-classic/your-altstore ; https://docs.github.com/en/actions/concepts/billing-and-usage ; https://developer.apple.com/documentation/avfoundation/avcapturevideostabilizationmode/cinematicextended
