# Guia de Instalação do Aether (GitHub Markdown)

<p align="center">
  <b>Aether</b> — Bot de Telegram com IA local rodando no Termux (Android)<br>
  <i>Guia rápido para clonagem, chaves, instalação e uso.</i>
</p>

---

## 📋 1. Visão Geral e Requisitos

O **Aether** é um bot de Telegram acionado por inteligência artificial local hospedada via **Ollama**. Ele roda dentro do **Termux** no Android e responde apenas aos IDs autorizados.

### 💻 Requisitos do Sistema (Android / Termux)
* **Internet** (Wi-Fi recomendado devido ao tamanho dos downloads).
* **3 a 6 GB** de armazenamento livre.
* **Termux** (Baixado obrigatoriamente pelo [F-Droid](https://f-droid.org/en/packages/com.termux/) ou [GitHub Releases](https://github.com/termux/termux-app/releases) — **não utilize a versão da Google Play Store** pois está desatualizada).
* *(Opcional)* **Termux: Widget** para atalhos na tela inicial.

---

## 🔑 2. Contas e Chaves Necessárias

| Serviço | Para que serve | Obrigatório? | Custo |
| :--- | :--- | :--- | :--- |
| **Telegram + @BotFather** | Criar o bot e obter o token (`TELEGRAM_BOT_TOKEN`) | **Sim** | Gratuito |
| **Telegram + @userinfobot** | Descobrir seu ID numérico para whitelist (`ALLOWED_USER_IDS`) | **Sim** | Gratuito |
| **Fish Audio** | Respostas em áudio/voz (`FISH_API_KEY`) | Opcional | Plano gratuito com limites |
| **Nexus-Bridge** | Recursos extras como `/video` e `/code` (`NEXUS_URL`) | Opcional | Servidor próprio |
| **Ollama** | Motor de IA local (`OLLAMA_HOST`) | **Sim** (Local ou remoto) | Gratuito e sem chave |

---

## ⚙️ 3. Como Instalar pelo Prompt de Comando (Termux)

Siga os passos abaixo diretamente no terminal do seu celular:

### Passo 1: Preparar o Armazenamento e Mover o Instalador
1. Baixe o arquivo do instalador (`install.sh`) e salve-o na pasta **Downloads** do seu celular.
2. Abra o **Termux** e libere o acesso aos arquivos do aparelho digitando:
   ```bash
   termux-setup-storage
   ```
   *(Uma janela do Android aparecerá solicitando permissão; toque em **Permitir**)*.
3. Copie o instalador para a raiz do Termux:
   ```bash
   cp /storage/downloads/install.sh ~/
   ```
   *(Nota: Se o seu gerenciador de arquivos renomeou o arquivo por ter uma cópia anterior, ex: `install (1).sh`, ajuste o comando `cp` para o nome correspondente).*

### Passo 2: Executar o Instalador
Entre na pasta home e execute o script usando o interpretador `bash`:
```bash
cd ~
bash install.sh
```

### O que acontece durante a instalação:
* O script verificará e instalará automaticamente o **Python 3.10+** e as dependências necessárias via `pkg`.
* Ele abrirá um menu interativo onde você poderá:
  1. Definir a pasta de instalação (Padrão: `~/Aether`).
  2. Escolher a personalidade do bot (JSON).
  3. Configurar as chaves do `.env` (manualmente ou importando um arquivo pronto).
  4. Indicar onde o Ollama roda (no próprio celular ou em outro PC na rede).
  5. Selecionar o modelo de IA compatível com a RAM do seu dispositivo.

---

## 🚀 4. Executar e Gerenciar o Bot

Após a conclusão da instalação, acesse a pasta do bot para gerenciá-lo com os comandos do launcher (`start.sh`):

* **Iniciar em primeiro plano** (Ctrl+C para parar):
  ```bash
  cd ~/Aether
  bash start.sh
  ```
* **Iniciar em segundo plano** (modo silencioso, logs salvos em `logs/bot.log`):
  ```bash
  bash start.sh silent
  ```
* **Verificar o status de execução**:
  ```bash
  bash start.sh status
  ```
* **Parar o bot**:
  ```bash
  bash start.sh stop
  ```
* **Acompanhar os logs em tempo real**:
  ```bash
  tail -f logs/bot.log
  ```

---

## 🛠️ 5. Manutenção e Solução de Problemas

* **Erro de pacotes no Termux (`pkg falha`)**: Certifique-se de estar usando a versão do F-Droid. No terminal, execute `termux-change-repo`, depois `pkg upgrade -y` e tente rodar o instalador novamente.
* **Token Recusado**: Verifique se copiou a string inteira do `@BotFather` (incluindo os dois-pontos).
* **O bot não responde**: Certifique-se de que enviou o comando `/start` diretamente para o seu bot no Telegram e que o seu ID numérico está correto na variável `ALLOWED_USER_IDS`.
* **Desativar Otimização de Bateria**: Para evitar que o Android feche o Termux em segundo plano, desative as restrições de bateria para o aplicativo nas configurações do sistema Android.
