# IT Support Toolkit V2

**Automated Windows Diagnostics & Safe Maintenance** — projeto gratuito de portfólio para suporte técnico N1/N2, infraestrutura e administração Windows.

> Estado: versão inicial de portfólio. O script foi escrito para Windows PowerShell 5.1+ e precisa ser validado em uma matriz real de Windows 10/11, hardware e políticas corporativas antes de uso em produção.

## Objetivos

- Diagnosticar condições comuns de computadores Windows.
- Produzir um relatório HTML individual por equipamento, adequado para anexar a chamados.
- Registrar ações de manutenção e resultados em log.
- Fazer backup de inventários/configurações selecionadas antes de reparos.
- Permitir auditoria semanal por Agendador de Tarefas.
- Manter o modo padrão somente leitura e exigir seleção explícita para cada reparo.

## Recursos

| Área | Verificações |
|---|---|
| Sistema | Versão/build do Windows, fabricante, modelo, domínio/workgroup e último boot |
| RAM/CPU | Memória total/livre, percentual usado e carga reportada da CPU |
| Disco | Espaço livre por volume e saúde reportada por `Get-PhysicalDisk`, quando disponível |
| Inicialização | Inventário via `Win32_StartupCommand`; não desativa entradas automaticamente |
| Webcam/áudio | Presença e status de dispositivos PnP, quando as classes estão disponíveis |
| Privacidade | Leitura de valores globais de webcam/microfone do usuário atual |
| Rede/DNS | Gateway, teste ICMP e resolução DNS pública de teste |
| Impressão | Estado do Spooler e inventário de trabalhos na fila |
| Eventos | Eventos recentes de energia, disco, NTFS, WHEA e bugcheck |
| Relatórios | HTML local com resumo, achados, recomendações, eventos e ações |

## Requisitos

- Windows 10 ou Windows 11.
- Windows PowerShell 5.1 ou PowerShell 7 no Windows (algumas funções dependem de módulos/cmdlets do Windows).
- Privilégios administrativos para reparos selecionados e instalação/remoção da tarefa semanal.
- `Get-PhysicalDisk`, `Get-PnpDevice`, `Get-NetIPConfiguration` e `Get-DnsClientServerAddress` dependem dos módulos/provedores disponíveis no Windows.

## Como executar

Abra PowerShell na pasta do projeto.

### 1. Auditoria (somente leitura)

```powershell
Set-ExecutionPolicy -Scope Process RemoteSigned
.\ITSupportToolkit.ps1 -Mode Audit
```

Relatório e logs são gravados em:

```text
%LOCALAPPDATA%\ITSupportToolkit\NOME-DO-PC\
```

### 2. Reparos opt-in

Cada ação é independente. Execute somente o que foi autorizado e apropriado para o equipamento:

```powershell
# Criar ponto de restauração (se a Proteção do Sistema estiver habilitada)
.\ITSupportToolkit.ps1 -Mode Repair -CreateRestorePoint

# Limpar cache DNS local
.\ITSupportToolkit.ps1 -Mode Repair -FlushDns

# Remover arquivos antigos apenas das pastas Temp do Windows e do usuário atual
.\ITSupportToolkit.ps1 -Mode Repair -CleanTemp -TempFileAgeDays 7

# Reiniciar o serviço de impressão sem apagar trabalhos da fila
.\ITSupportToolkit.ps1 -Mode Repair -RestartSpooler

# Reparar imagem do Windows / verificar arquivos protegidos (demorado)
.\ITSupportToolkit.ps1 -Mode Repair -RunDISM -RunSFC
```

**Atenção:** cada execução de `Repair` cria backup de inventário/configurações selecionadas antes das ações. O ponto de restauração é uma tentativa: o Windows pode limitar sua frequência ou não permitir sua criação. Backups de configuração não equivalem a backup completo do sistema.

### 3. Auditoria semanal

Instalar (segunda-feira, 08:00 por padrão):

```powershell
.\ITSupportToolkit.ps1 -Mode InstallWeekly
```

Outro horário:

```powershell
.\ITSupportToolkit.ps1 -Mode InstallWeekly -TaskTime '18:30'
```

Remover:

```powershell
.\ITSupportToolkit.ps1 -Mode UninstallWeekly
```

A tarefa semanal executa **somente auditoria**, não faz reparos. O computador precisa estar ligado; a opção `StartWhenAvailable` permite executar quando a tarefa perder o horário agendado. A tarefa roda sob a identidade/configuração de segurança do usuário que a instalou.

## Segurança e privacidade

- Não lê, exporta ou altera senhas.
- Não acessa histórico de navegação, cookies ou conteúdo de navegadores.
- Não remove documentos, fotos, Downloads ou arquivos pessoais.
- A limpeza opcional limita-se a arquivos antigos em `%TEMP%` do usuário atual e `C:\Windows\Temp`; arquivos bloqueados são ignorados.
- Não desativa programas de inicialização, serviços, firewall, antivírus ou controles de privacidade.
- Não altera permissões de webcam/microfone.
- Não apaga trabalhos da fila de impressão.
- Não executa reparos automaticamente na tarefa semanal.
- Recomenda-se revisar relatórios antes de anexá-los a chamados: nomes de usuário, nomes de máquina, caminhos e eventos podem conter dados corporativos. Trate-os conforme LGPD e política interna.

## Limitações conhecidas

- O Windows não fornece uma API universal para medir temperatura de CPU/GPU; este projeto não inventa esses valores.
- Dados SMART/saúde dependem do driver, controlador e provedor de armazenamento. `Unknown` é reportado como não verificado, não como saudável.
- Status PnP não garante que webcam/microfone funcionem dentro do Teams. Testes de chamada e permissões por aplicativo ainda exigem validação no cliente.
- A leitura de privacidade no Registro é parcial e contextual ao usuário que executa o script.
- Teste DNS usa `www.microsoft.com`; ambientes com proxy, VPN, DNS split-horizon ou bloqueios podem produzir falsos negativos.
- ICMP pode ser bloqueado por política mesmo com rede funcional.
- Evento Kernel-Power 41 indica desligamento inesperado, mas não determina sozinho a causa.
- O backup é de inventário e chaves selecionadas de inicialização, não restauração automática de todas as configurações.
- O relatório pode conter mensagens de eventos com informações internas; revise antes de compartilhar externamente.

## Estrutura

```text
IT-Support-Toolkit/
├── ITSupportToolkit.ps1
├── README.md
├── LEIA-ME.txt
├── LICENSE
└── .gitignore
```

## Roadmap sugerido

- [ ] Testes em Windows 10 e Windows 11 (físico e VM).
- [ ] Separar coleta, reparos e renderização HTML em módulos.
- [ ] Adicionar exportação JSON para integração com inventário/ITSM.
- [ ] Criar modo interativo para seleção de correções.
- [ ] Melhorar diagnóstico de Teams sem coletar conteúdo pessoal.
- [ ] Adicionar baseline de desempenho por máquina e histórico comparativo.
- [ ] Assinar digitalmente o script para distribuição corporativa.
- [ ] Validar execução via GPO/Intune e conta de serviço, com permissões mínimas.

## Aviso

Projeto educacional/de portfólio. Não é uma ferramenta certificada nem substitui backup corporativo, EDR, monitoramento, diagnóstico do fabricante ou processo formal de mudanças. Teste em laboratório e obtenha autorização antes de executar em equipamentos de produção.

## Licença

MIT — consulte `LICENSE`.
