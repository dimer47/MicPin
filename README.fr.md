# MicPin

*[English version](README.md)*

Un petit utilitaire de barre des menus pour macOS qui épingle votre micro d'entrée et son volume, pour que macOS cesse de les changer dans votre dos.

![L'interface de MicPin](docs/panel.png)

## Le problème

macOS promeut spontanément tout nouveau périphérique audio en entrée par défaut. Vous branchez des écouteurs, vous appairez un casque Bluetooth, une app ouvre un périphérique virtuel — et votre micro intégré n'est plus celui qui capte. Pire : chaque périphérique conserve son propre niveau d'entrée, donc le volume change en même temps que la source.

On s'en aperçoit généralement au milieu d'un appel, quand quelqu'un demande pourquoi on l'entend mal.

MicPin corrige les deux : il épingle le micro **et** son volume, et les restaure dès que macOS s'en écarte.

## Fonctionnalités

- **Choisir sa source** — tous les micros disponibles dans un menu, avec leur type de connexion.
- **Régler le niveau d'entrée** — un curseur, sans passer par les Réglages Système.
- **Épingler un micro** — MicPin surveille les bascules et remet aussitôt le périphérique voulu et son volume.
- **Léger** — application native SwiftUI, aucun driver audio virtuel, aucune dépendance externe.
- **Discret** — vit dans la barre des menus, pas d'icône dans le Dock.

## Installation

Aucune version compilée n'est distribuée pour l'instant : le projet se construit depuis les sources.

```bash
git clone https://github.com/dimer47/MicPin.git
cd MicPin
xcodebuild -project MicPin.xcodeproj -scheme MicPin -configuration Release build
```

Copiez ensuite l'app construite dans `/Applications` :

```bash
cp -R ~/Library/Developer/Xcode/DerivedData/MicPin-*/Build/Products/Release/MicPin.app /Applications/
```

L'emplacement compte : `SMAppService` refuse d'enregistrer le lancement au démarrage pour une app située ailleurs que dans `/Applications`.

**Prérequis** : macOS 26 ou ultérieur, Xcode 26 pour compiler.

## Utilisation

1. Lancez MicPin — son icône apparaît dans la barre des menus.
2. Cliquez dessus pour voir vos micros, choisissez-en un.
3. Réglez le niveau d'entrée au curseur.
4. Cliquez sur l'épingle pour verrouiller ce micro et son volume.

Une fois épinglé, l'icône de la barre change et MicPin restaure votre choix à chaque tentative de bascule de macOS. Cliquez de nouveau sur l'épingle pour lever le verrouillage.

### Si l'icône n'apparaît pas

Une barre des menus saturée empêche macOS d'attribuer un emplacement visible aux nouveaux éléments. Libérez de la place en faisant glisser une icône hors de la barre avec la touche Cmd enfoncée, ou utilisez un gestionnaire de barre des menus.

## Détails techniques

Trois décisions valent d'être expliquées, parce qu'elles ne sont pas évidentes à la lecture.

**La persistance se fait par UID, pas par identifiant de périphérique.** L'`AudioObjectID` que CoreAudio attribue à un périphérique change à chaque rebranchement. L'UID, lui, survit aux redémarrages : c'est donc lui qui est mémorisé, ce qui permet à l'épinglage de tenir quand vous débranchez puis rebranchez le micro.

**La reprise en main est bornée.** Si un périphérique refusait obstinément de rester sélectionné, réécrire l'entrée par défaut en boucle ferait tourner l'app indéfiniment contre CoreAudio. MicPin limite les restaurations à cinq par tranche de dix secondes, et lève l'épinglage au-delà plutôt que de s'acharner.

**Le curseur de volume se grise sur certains micros.** Beaucoup de périphériques USB et Bluetooth n'exposent pas `kAudioDevicePropertyVolumeScalar` en écriture : leur gain est géré par le matériel. MicPin détecte le cas et l'explique, plutôt que de laisser un contrôle inerte.

### Architecture

| Fichier | Rôle |
|---|---|
| `CoreAudioBridge.swift` | Accès bas niveau à CoreAudio : énumération, lecture et écriture des propriétés, observateurs |
| `MicrophoneController.swift` | État de l'app et logique d'épinglage |
| `AudioDevice.swift` | Description d'un périphérique d'entrée |
| `Preferences.swift` | Persistance et lancement au démarrage |
| `MenuContentView.swift` | Le panneau de la barre des menus |
| `MenuBarIcon.swift` | Fabrication de l'icône de la barre |

L'app n'est pas en bac à sable : lire et modifier les périphériques audio du système l'exige.

## Licence

GPL-3.0. Voir [LICENSE](LICENSE).
