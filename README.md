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
