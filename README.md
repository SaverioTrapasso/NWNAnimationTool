# NWNAnimationTool

Tool Godot per posare il dummy IK di Neverwinter Nights e esportare la posa
come blocco di animazione MDL ASCII (`newanim ... doneanim`), pronto per
essere incollato in un file `.mdl` di NWN.

## Come avviarlo

1. Scarica [Godot 4.7](https://godotengine.org/download) (versione standard, non serve .NET).
2. Apri Godot, scegli "Import" e seleziona il file `project.godot` di questo repository.
3. Premi **Play** (in alto a destra, oppure F5).

Non serve nessuna build: GDScript viene interpretato direttamente dal motore.

## Uso rapido

- Clicca su un componente del corpo per selezionarlo: **azzurro** = parti FK
  (testa, torso, bacino, ruotabili con il gizmo a 3 assi), **giallo** = mani/piedi
  (trascinabili in IK, con pole vector per gomiti/ginocchia).
- Seleziona il bacino per trascinare anche l'handle verde e alzare/abbassare
  l'intero corpo.
- "Show all pole vectors" mostra i pole vector di tutti gli arti insieme, utile
  per revisionare la posa.
- "Hide cloak/tabard" e "Show weapons" sono toggle visivi di comodo per la posa.
- "Reset pose" riporta il rig alla posa originale del modello importato.
- Inserisci un nome animazione e premi **Save** per esportare il file `.txt`
  con il blocco MDL ASCII.

## Note

- La cartella `SDK/` (eseguibili di Godot) non è inclusa nel repository per le
  dimensioni: scarica Godot 4.7 separatamente come descritto sopra.
- Il modello del dummy (`assets/a_ba.glb`) deve avere i nomi dei nodi NWN
  esatti (`rootdummy`, `torso_g`, `pelvis_g`, ecc.) — vedi [CLAUDE.md](CLAUDE.md)
  per i dettagli sul formato di export.
