# 🎨 Open WebUI: Lokale Bildgenerierung, Modell-Setup & LLM-Kombinationen

> **Hardware-Basis:** AMD Radeon PRO W7800 (48 GB VRAM, Netto **~45,0 GiB** nutzbar) | 64 GB System-RAM | ROCm 6.4 nativ | Ubuntu Linux  
> **Architektur:** Open WebUI (Docker, Port 3000) ⇄ ComfyUI nativ (Port 8188) ⇄ Ollama nativ (Port 11434)  
> **Stand:** Oktober 2026

---

## 📑 Inhaltsverzeichnis
1. [Status Quo: Ist FLUX.1 deprecated & Was ist lokal vorhanden?](#1-status-quo-ist-flux1-deprecated--was-ist-lokal-vorhanden)
2. [Master-Kompatibilitätstabelle: Bildmodelle (.safetensors) & parallele LLMs](#2-master-kompatibilitätstabelle-bildmodelle-safetensors--parallele-llms)
3. [Die 3 idealen Kombinationen aus LLM und Bildgenerierung](#3-die-3-idealen-kombinationen-aus-llm-und-bildgenerierung)
4. [Schritt-für-Schritt: Konfiguration in Open WebUI](#4-schritt-für-schritt-konfiguration-in-open-webui)
   - [Felder in den Einstellungen](#a-felder-in-den-einstellungen-admin-panel--einstellungen--bilder)
   - [Workflow-Node-Mapping](#b-mapping-der-comfyui-workflow-nodes)
5. [VRAM-Sicherheitsregeln & Speicherbereinigung](#5-vram-sicherheitsregeln--speicherbereinigung)

---

## 1. Status Quo: Ist FLUX.1 deprecated & Was ist lokal vorhanden?

### Ist FLUX.1 veraltet (deprecated)?
* **Lokal (Open Weights): NEIN.**  
  Die Modelle `FLUX.1 [dev]` und `FLUX.1 [schnell]` sind weiterhin erstklassige, aktive Open-Source-Modelle.
* **Woher das Missverständnis kommt:**
  1. **Cloud-API:** Black Forest Labs (BFL) hat in ihrer Cloud-API die ursprüngliche Version 1.0 zugunsten von *FLUX 1.1 [pro]* bzw. Nachfolgern als deprecated markiert.
  2. **Community-Plugins:** Ältere Drittanbieter-Plugins für Open WebUI wurden teils archiviert.
  3. **Ollama:** Ollama kann keine Diffusionsmodelle laden (`ollama pull flux` existiert nicht).

### Dein lokaler Modell-Bestand (ComfyUI)
Auf deiner Workstation ist **FLUX.2 bereits vollständig installiert**:
* **Diffusions-Kern:** `models/diffusion_models/flux2_dev_fp8mixed.safetensors` (33 GB)
* **Text-Encoder:** `models/text_encoders/mistral_3_small_flux2_fp8.safetensors` (17 GB)
* **VAE:** `models/vae/flux2-vae.safetensors` (321 MB)
* **Turbo-LoRA:** `models/loras/Flux_2-Turbo-LoRA_comfyui.safetensors` (2,6 GB)

> [!IMPORTANT]
> **Konsequenz:** Da du **FLUX.2 [dev]** lokal einsatzbereit hast, ist **`FLUX.1 [dev]` redundant**. Es bedient dieselbe Nische, wird aber von FLUX.2 in Detailgrad, Texturen und Multi-Referenz übertroffen. Durch das Löschen nicht mehr benötigter Checkpoints (`flux1-dev`, `sd3.5`, `sd_xl_base`) können **ca. 55 GB SSD-Speicher** freigegeben werden.

---

## 2. Master-Kompatibilitätstabelle: Bildmodelle (.safetensors) & parallele LLMs

Damit dein System niemals einfriert, muss die VRAM-Regel eingehalten werden:
$$\text{VRAM}_{\text{LLM}} + \text{VRAM}_{\text{Bild}} \le 45{,}0\text{ GiB}$$

Alle monolithischen Checkpoints aus `ComfyUI/models/checkpoints/` können direkt im Open WebUI Feld **„Modell“** eingetragen werden:

| Dateiname für Open WebUI (`.safetensors`) | Dateigröße (SSD) | VRAM (ComfyUI) | Renderzeit (W7800) | 🟢 Parallele LLMs im Chat (Stabil) | ❌ Nicht gleichzeitig möglich (Freeze-Gefahr) |
| :--- | :---: | :---: | :---: | :--- | :--- |
| **`Juggernaut-XL_v9_RunDiffusionPhoto.safetensors`** <br>*(🏆 Top-Empfehlung für Chat)* | **6,6 GB** | **~7,5 GB** | **~3–5 s** | • `qwen3.8-35b-distill` (~33 GB)<br>• `artemis-31b` (~33 GB)<br>• `qwen3-coder` (~33 GB)<br>• `qwen3.8-27b-q4` (~18 GB) | • `qwen3-next-80b` (43 GB) |
| **`flux1-schnell-fp8.safetensors`** <br>*(🗑️ Gelöscht / Bereinigt)* | ~~17,0 GB~~ | — | — | — | — |
| **`flux1-dev-fp8.safetensors`** <br>*(Redundant zu FLUX.2)* | **17,2 GB** | **~18,0 GB** | **~20–25 s** | • **Nur** `qwen3.8-27b-q4` (~18 GB) | • Alle 31B-, 35B- & 80B-Modelle |
| **`sd3.5_large_fp8_scaled.safetensors`** | **14,9 GB** | **~16,0 GB** | **~18–22 s** | • **Nur** `qwen3.8-27b-q4` (~18 GB)<br>*(Summe: ~34 GB / 45 GB)* | • Alle 31B-, 35B- & 80B-Modelle |
| **`sd_xl_base_1.0.safetensors`** | **6,5 GB** | **~7,5 GB** | **~4–6 s** | • `qwen3.8-35b-distill`<br>• `artemis-31b`<br>• `qwen3-coder`<br>• `qwen3.8-27b-q4` | • `qwen3-next-80b` (43 GB) |

### Sonderfall: `FLUX.2 [dev]` (Modulares Baukasten-Modell)
* **Dateipfad:** `models/diffusion_models/flux2_dev_fp8mixed.safetensors` (33 GB + 17 GB Mistral Text-Encoder).
* **VRAM-Bedarf:** **~36–40 GB**.
* **Parallele LLMs:** ❌ **Kein LLM passt gleichzeitig in den Speicher!**  
  $(38\text{ GB} + 18\text{–}33\text{ GB} > 48\text{ GB})$.
* **Betriebsart:** **Sequenziell.** Du lässt dir vom LLM den Prompt schreiben; während FLUX.2 rendert, entlädt Ollama den Speicher. Bei der nächsten Chat-Nachricht lädt die NVMe das LLM in 3–4 Sekunden wieder in die GPU.
* **Open WebUI Anbindung:** Benötigt den Upload des Workflows `flux2_t2i.json` (da UNETLoader statt CheckpointLoader genutzt wird).

---

## 3. Die 3 idealen Kombinationen aus LLM und Bildgenerierung

### 🥇 Kombination 1: Der unschlagbare Alltags- & Chat-König (Empfehlung!)
* **LLM (Ollama):** `qwen3.8-35b-distill` *(oder `qwen3-coder`)* $\rightarrow$ **~33 GB VRAM**
* **Bildmodell (ComfyUI):** `Juggernaut-XL_v9_RunDiffusionPhoto.safetensors` $\rightarrow$ **~7,5 GB VRAM**
* **VRAM-Bilanz:** $33 + 7{,}5 = \mathbf{40{,}5\text{ GB / 45{,}0 GB}}$ 🟢 **100% stabil & grün**
* **Vorteil:**
  * Du behältst dein stärkstes Reasoning-/Coding-Modell dauerhaft im Chat aktiv.
  * Wenn du ein Bild anforderst, liefert Juggernaut XL in **3 bis 5 Sekunden** kinoreife Fotos im 35mm-Analogfilmlook.
  * Kein Speicherstau, kein Entladen nötig, null Latenz.

---

### 🎨 Kombination 2: Der kreative Bild-Poet (Atmosphäre & Rollenspiel)
* **LLM (Ollama):** `artemis-31b` $\rightarrow$ **~33 GB VRAM**
* **Bildmodell (ComfyUI):** `Juggernaut-XL_v9_RunDiffusionPhoto.safetensors` $\rightarrow$ **~7,5 GB VRAM**
* **VRAM-Bilanz:** $33 + 7{,}5 = \mathbf{40{,}5\text{ GB / 45{,}0 GB}}$ 🟢 **Grüne Zone**
* **Vorteil:**
  * `artemis-31b` formuliert meisterhafte, bildhafte Prompts (Lichtstimmung, Kameralinse, Materialien, Atmosphäre).
  * Juggernaut XL setzt diese detailreichen Beschreibungen perfekt fotorealistisch um.

---

### 🏆 Kombination 3: Das High-End Meisterwerk-Studio (FLUX.2 Next-Gen)
* **LLM (Ollama):** `qwen3.8-35b-distill` *(zur Prompt-Ausarbeitung)*
* **Bildmodell (ComfyUI):** `FLUX.2 [dev]` *(Workflow: `flux2_t2i.json`)* $\rightarrow$ **~38 GB VRAM**
* **VRAM-Bilanz:** Sequenzieller Betrieb (Ollama-Timeout gibt VRAM für FLUX.2 frei).
* **Vorteil:**
  * Höchste am Markt verfügbare Open-Source-Bildqualität.
  * Makellose Hände, natürliche Hautporen, Multi-Referenz-Konsistenz.

---

## 4. Schritt-für-Schritt: Konfiguration in Open WebUI

Navigiere in Open WebUI zu:  
**Profil-Symbol (unten links) → Admin-Panel → Einstellungen → Bilder** (*Settings > Images*)

### A. Felder in den Einstellungen

| Feld | Wert für Juggernaut XL *(Empfohlen)* | Wert für FLUX.1 Schnell |
| :--- | :--- | :--- |
| **Bildgenerierung** | `AN` (Toggle rechts oben) | `AN` (Toggle rechts oben) |
| **Bildgenerierungs-Engine** | `ComfyUI` | `ComfyUI` |
| **Modell** | `Juggernaut-XL_v9_RunDiffusionPhoto.safetensors` | `flux1-schnell-fp8.safetensors` |
| **Bildgröße** | `1024x1024` *(oder `832x1216`)* | `1024x1024` |
| **Schritte** | `25` | `4` |
| **Bild-Prompt-Generierung** | `AN` *(optimiert Prompts auf Englisch)* | `AN` |
| **Basis-URL** | `http://100.x.y.z:8188` | `http://100.x.y.z:8188` |
| **API-Schlüssel** | *(Leer lassen)* | *(Leer lassen)* |

---

### B. Mapping der ComfyUI-Workflow-Nodes

Open WebUI nutzt standardmäßig einen integrierten Standard-Workflow. Trage unter **ComfyUI-Workflow-Nodes** folgende Node-IDs ein:

| Feldname in Open WebUI | Einzutragende Node-ID | Funktion im ComfyUI-Workflow |
| :--- | :---: | :--- |
| **Prompt\*** *(Pflichtfeld)* | **`6`** | Node: `CLIPTextEncode` (Positiver Prompt) |
| **Modell** | **`4`** | Node: `CheckpointLoaderSimple` (`ckpt_name`) |
| **Breite (Width)** | **`5`** | Node: `EmptyLatentImage` (`width`) |
| **Höhe (Height)** | **`5`** | Node: `EmptyLatentImage` (`height`) |
| **Schritte (Steps)** | **`3`** | Node: `KSampler` (`steps`) |
| **Seed** | **`3`** | Node: `KSampler` (`seed`) |

> [!TIP]
> Klicke nach dem Eintragen ganz unten auf **Speichern**. Die Einstellung ist sofort aktiv.

---

## 5. VRAM-Sicherheitsregeln & Speicherbereinigung

1. **Die 80B-Modell-Regel:**  
   Wenn du mit `qwen3-next-80b` arbeitest, belegt dieses Modell bereits **~43 GB VRAM**. In diesem Modus darf **keine Bildgenerierung** parallel aufgerufen werden.
2. **Großes LLM (35B) + FLUX gleichzeitig:**  
   Starte niemals einen FLUX.1/FLUX.2-Render, solange ein 35B-LLM aktiv im VRAM geladen ist. Nutze für parallele FLUX-Chats `qwen3.8-27b-q4`.
3. **1-Klick-Speicherbereinigung bei Engpässen:**  
   Sollte der VRAM nach langen Sessions voll sein, führe im Terminal aus:
   ```bash
   /home/clemi/Projekte/LLM/image-video-setup/free_vram.sh
   ```
   *(Entlädt sofort alle aktiven Ollama-Modelle und ComfyUI-Speichercaches per API).*

