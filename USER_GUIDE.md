# Scarlett MixControl Companion

## Guia do usuário

**Scarlett 18i8, 1ª geração · macOS**

---

## Conteúdo

1. [Introdução](#introdução)
2. [Primeiros passos](#primeiros-passos)
3. [Visão geral](#visão-geral)
4. [Mixer e medidores](#mixer-e-medidores)
5. [Routing](#routing)
6. [Device](#device)
7. [Snapshots](#snapshots)
8. [Solução de problemas](#solução-de-problemas)

## Introdução

O Scarlett MixControl Companion é uma ferramenta local para consultar e controlar
recursos selecionados da Scarlett 18i8 de primeira geração no macOS.

> **Importante:** os controles experimentais de fonte, monitores e Headphone 01 descritos
> abaixo enviam comandos reais, mas não conseguem confirmar o estado por releitura.
> O aplicativo ainda não substitui todas as funções do Scarlett MixControl.

Os controles reais exigem uma ação explícita; abrir a página não altera as
configurações do dispositivo.

## Primeiros passos

### Requisitos

- macOS, Node.js e Swift 5.9 ou posterior.
- Scarlett 18i8 de primeira geração conectada por USB para os controles e
  medições da Scarlett.
- Para o medidor de saída: macOS 14.2 ou posterior e, quando solicitada,
  permissão para gravação de áudio do sistema.

### Abrir o aplicativo

No Terminal, a partir da pasta do projeto, execute:

```sh
swift build --package-path tools/scarlett-device-probe
node tools/playground-server.mjs
```

Abra `http://127.0.0.1:8787` no navegador. Mantenha o servidor em execução
enquanto estiver usando a interface. O indicador no topo informa o estado da
conexão com a ponte local.

> **Nota:** o macOS pode solicitar acesso ao microfone para medir entradas. O
> áudio das medições é processado em memória e não é salvo.

## Visão geral

| Área | Função |
| --- | --- |
| **Mixer** | Medidores de entrada e saída e seleção experimental de fonte. |
| **Routing** | Presets experimentais, teste de saídas, monitoramento por software e saída padrão do macOS. |
| **Device** | Estado do dispositivo, controles reais e medições de entrada. |
| **Snapshot** | Salvar e restaurar configurações verificadas de hardware. |

O seletor **Dark / Light** altera o tema e guarda a preferência no navegador.
Para alterar a frequência ou o clock, use os controles correspondentes na aba
**Device**.

## Mixer e medidores

### Medidores ao vivo

Selecione **Start input meters** para acompanhar as entradas CoreAudio 1–18.
Selecione **Start output meter** para acompanhar as saídas CoreAudio 1–8.
Use os mesmos botões para interromper os fluxos.

O medidor de saída observa o áudio do computador enviado à Scarlett; sinais
monitorados diretamente pela matriz interna podem não aparecer. Os medidores
parados indicam **Stopped**.

Cada par de saídas mostra **Host tap** e **Software monitor** separadamente.
Eles podem funcionar ao mesmo tempo: o primeiro mostra o sinal captado pelo
tap do macOS, enquanto o segundo mostra o sinal que o companion envia pelo
monitoramento por software. O tap também pode incluir esse sinal; os valores
não devem ser somados e não representam necessariamente a saída física final.
Pares não selecionados no software monitor indicam **Not selected**.

### Audio source select experimental

Em **Audio source select**, selecione DAW 7 ou DAW 8 e pressione **Send source**.
Esta opção atua no canal 18 da matriz de hardware, compartilhado pelos mixes;
portanto, pode alterar o áudio em outros mixes e saídas. As demais fontes e
canais ainda não estão disponíveis neste controle. A aplicação não consegue
verificar se a fonte já está atribuída a outro canal.

Para ajustar a contribuição desse canal ao **Mix 1**, selecione **Off** ou
**-12 dB** e pressione **Send gain**. Para escutá-lo pelo lado esquerdo do
Headphone 01, use a opção **Mix 1 left / DAW 2 right** na aba **Routing**.
Outros canais também podem contribuir ao Mix 1.

> **Cuidado:** comece com volume baixo. O aplicativo informa que o comando foi
> enviado, mas não consegue confirmar a alteração ou recuperar os valores
> anteriores. Os seletores não representam o estado atual do dispositivo.
> Os caminhos experimentais foram testados em 44,1 kHz; outras frequências
> ainda não foram verificadas.

## Routing

### Roteamento experimental dos monitores

Em **Monitor Outputs 1/2**, selecione **DAW 1/2** e pressione **Send Monitor
1/2 route**. O comando tenta substituir as fontes atuais dos dois monitores
pelas saídas do computador DAW 1 e 2. O Monitor Output 1 foi validado por
escuta; o Monitor Output 2 ainda não foi testado separadamente.

> **Cuidado:** abaixe o volume dos monitores antes de enviar. Não há releitura
> confiável nem restauração automática; uma falha pode alterar apenas um lado.
> A mensagem indica comando enviado, não um estado confirmado.

Para tentar ouvir o computador nos monitores e a Input 1 no HP 01, mantenha
**Mixing** no Headphone 01 e use o **software monitor** com somente
**Headphone 01** selecionado. Confirme que a Input 1 deixou de ser ouvida nos
monitores: outra aplicação ou caminho de áudio também pode enviá-la para DAW
1/2. Esse monitoramento usa o computador e pode adicionar latência.

### Presets experimentais do Headphone 01

Em **Routing presets**, escolha uma opção e pressione **Send Headphone 01
route**:

| Opção | Headphone 01 esquerdo / direito |
| --- | --- |
| **Clear** | Desligado / desligado |
| **DAW Tracking** | DAW 1 / DAW 2 |
| **Mixing** | DAW 3 / DAW 4 |
| **Mix 1 left / DAW 2 right** | Mix 1 / DAW 2 |

Essas opções afetam **somente o Headphone 01**, não todas as saídas como os
presets completos do aplicativo original. A alteração envolve dois comandos:
se ocorrer falha, um lado pode ter mudado e o outro não. Não há releitura
confiável nem restauração automática; confira o áudio antes de aumentar o volume.

### Teste de mapeamento de saída

Em **CoreAudio output mapping test**, escolha um canal ou par de canais e
pressione **Play 440 Hz tone**. O tom é temporizado e termina automaticamente.
Ouça ou meça a saída física para identificar a correspondência com o canal
CoreAudio.

> **Cuidado:** comece com o volume de fones e monitores baixo. A correspondência
> entre canais CoreAudio e conectores físicos ainda precisa de confirmação.

### Monitoramento por software

Em **Standalone software monitor**, selecione os destinos e ajuste o ganho entre
-30 e 0 dB. Pressione **Start software monitor** para copiar a entrada CoreAudio
1 às saídas selecionadas. Pressione **Stop software monitor** para parar; fechar
o fluxo também interrompe a cópia.

Este caminho usa o computador e pode adicionar latência. Não é monitoramento
direto de latência zero e não altera a matriz interna da Scarlett. Desative
outros caminhos de monitoramento do mesmo sinal para evitar áudio duplicado e
comece com o volume baixo.

### Saída padrão do macOS

**Apply Scarlett output** define a Scarlett como saída padrão do sistema e
confirma a alteração por releitura. **Restore previous output** tenta restaurar
a saída anterior. Aplicativos como DAWs podem usar sua própria seleção de
dispositivo; esta operação não altera a matriz da Scarlett.

## Device

### Estado do dispositivo

Use **Refresh status** para atualizar os dados de conexão, canais, frequência,
clock, dispositivos padrão e informações USB. Uma leitura não altera o hardware.

### Entrada e saída padrão do sistema

Em **macOS default input** ou **macOS default output**, escolha um dispositivo
e pressione o respectivo botão **Apply**. A alteração é global no macOS e é
verificada por releitura. A DAW pode manter uma seleção diferente.

### Sample rate e clock

Em **Scarlett sample rate** ou **Scarlett clock source**, escolha uma opção
oferecida pelo dispositivo e pressione **Apply**. O aplicativo verifica o valor
após a alteração.

> **Nota:** essas alterações podem interromper áudio em outros aplicativos.
> Para clock externo, conecte uma fonte S/PDIF ou ADAT válida antes de usá-la.

### Line / Inst e PAD

Para as entradas 1 e 2, selecione a entrada em **Input 1-2 mode**, use **Read
mode** para consultar e **Set Line** ou **Set Inst** para alterar. O resultado é
verificado por releitura; isso não ajusta o ganho.

Para o PAD das entradas 1–4, selecione a entrada e pressione **Read PAD**.
Marque ou desmarque **PAD on** e pressione **Apply PAD**. O PAD atenua o sinal
analógico e pode afetar todos os aplicativos que usam a entrada.

### Consulta de ganho

Em **Input gain**, selecione uma entrada de 1 a 8 e pressione **Read current
gain**. O resultado é um byte de protocolo ainda não interpretado: não é um
valor em dB e não altera o ganho físico.

### Medição de sinal

Em **Instrument signal**, selecione uma entrada CoreAudio e pressione **Measure
signal (2 s)**. O resultado apresenta RMS, pico e comparação com o limiar
**Presence threshold**. As últimas dez medições permanecem somente na página.

Use **Scan all inputs (2 s)** para medir as 18 entradas simultaneamente. O
limiar indica apenas o nível do sinal, não comprova a conexão de um cabo ou
instrumento. O número do canal CoreAudio ainda não confirma o conector físico.

## Snapshots

Os snapshots ficam no armazenamento local do navegador, não em um arquivo
compartilhado com a Scarlett.

1. Digite um nome e pressione **Save live** para consultar e salvar as
   configurações verificadas de hardware.
2. Digite o mesmo nome e pressione **Apply hardware** para tentar restaurar as configurações
   salvas. A aplicação compara os valores atuais e verifica cada alteração.

O snapshot de hardware inclui dispositivos padrão do macOS, sample rate e
clock da Scarlett, Line/Inst das entradas 1–2 e PAD das entradas 1–4. A
mixagem e o roteamento interno, incluindo os controles experimentais, não são
restaurados. Snapshots antigos com estado de hardware continuam compatíveis;
seus campos antigos de interface são ignorados. Se uma aplicação falhar,
as alterações anteriores podem já ter sido feitas; confira o estado exibido.

## Solução de problemas

- **Scarlett não encontrada:** confirme a conexão USB, execute o servidor local
  e pressione **Refresh status**. Os controles Scarlett são destinados à
  18i8 de primeira geração.
- **Medidor sem sinal:** verifique a fonte, o canal CoreAudio e as permissões
  do macOS. O medidor de saída não necessariamente inclui monitoramento direto.
- **Áudio duplicado ou atrasado:** interrompa o monitoramento por software ou
  desative outros caminhos que monitorem a mesma entrada.
- **Alteração rejeitada:** leia a mensagem apresentada e confira se o
  dispositivo e a opção selecionada ainda estão disponíveis.
- **Snapshot não encontrado:** use o mesmo navegador e o nome usado ao salvar;
  os dados pertencem ao armazenamento local desse navegador.

Para comandos de diagnóstico e detalhes da API local, consulte o
[README](README.md).
