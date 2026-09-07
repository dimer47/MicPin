# Publier une version

La publication est automatisée : pousser un tag `v…` déclenche la compilation,
la signature, la notarisation par Apple, la fabrication du disque d'installation
et la création de la release GitHub.

```bash
git tag v1.1.0
git push origin v1.1.0
```

Le numéro de version est repris du tag et inscrit dans l'app à la compilation :
il n'y a rien à modifier dans le projet au préalable.

## Réglage initial des secrets

Quatre secrets sont à enregistrer une seule fois sur le dépôt. Sans eux, le
workflow s'arrête avec un message explicite.

### 1. Le certificat Developer ID

Dans Xcode : **Réglages → Comptes → Manage Certificates**, puis clic droit sur le
certificat *Developer ID Application* → **Export**. Choisissez un mot de passe :
un `.p12` exporté sans mot de passe ne peut pas être importé par macOS sur le
runner.

```bash
base64 -i certificat.p12 -o certificat.b64
gh secret set CERTIFICAT_P12_BASE64 --repo dimer47/MicPin < certificat.b64
gh secret set CERTIFICAT_MOT_DE_PASSE --repo dimer47/MicPin
rm certificat.p12 certificat.b64
```

Le `< fichier` compte : passer le base64 en argument de ligne de commande le
laisserait dans l'historique du shell.

### 2. Le mot de passe de notarisation

Ce n'est pas le mot de passe du compte Apple, mais un **mot de passe
d'application** créé sur [appleid.apple.com](https://appleid.apple.com) →
Connexion et sécurité → Mots de passe des apps.

```bash
gh secret set NOTARISATION_MOT_DE_PASSE --repo dimer47/MicPin
```

### 3. L'identifiant du compte Apple

L'adresse du compte développeur, employée par `notarytool`. Elle est enregistrée en
secret plutôt qu'écrite dans le workflow : le dépôt est public, et une adresse en clair
dans un fichier versionné finit récoltée.

```bash
gh secret set IDENTIFIANT_APPLE --repo dimer47/MicPin
```

### 4. Vérifier l'identifiant d'équipe

L'identifiant d'équipe, lui, reste en clair dans le workflow : il est de toute façon
lisible dans la signature de tout binaire distribué (`codesign -dv`), et le vérificateur
de mise à jour doit le connaître pour refuser un disque signé par un tiers.

Le workflow et le vérificateur attendent tous deux l'équipe `5D6QHL72QC`. Si le compte développeur change, il faut modifier `EQUIPE_APPLE`
dans `.github/workflows/release.yml` **et** `expectedTeamID` dans
`MicPin/Sources/UpdateChecker.swift` — sans quoi les mises à jour seront
refusées comme non signées par l'auteur.

## Ce que fait le workflow

1. Importe le certificat dans un trousseau temporaire, détruit en fin d'exécution.
2. Inscrit la version du tag dans `Info.plist`.
3. Lance la suite de tests — un échec interrompt la publication.
4. Compile en Release avec le runtime durci, exigé par la notarisation.
5. Resigne sans `get-task-allow` : Xcode ajoute ce droit de débogage même en
   Release, et Apple rejette toute soumission qui le déclare.
6. Vérifie que la version embarquée correspond au tag.
7. Soumet l'app à la notarisation, puis agrafe le ticket.
8. Fabrique le disque d'installation, le signe, le fait notariser et l'agrafe.
9. Vérifie le verdict `spctl` — le même que le vérificateur de mise à jour
   exigera avant d'installer.
10. Publie la release avec le disque en pièce jointe.

## Mise à jour côté utilisateur

L'app interroge une fois par jour la dernière release publique du dépôt, compare
sa version, et propose l'installation. Le disque téléchargé n'est jamais installé
sans que sa signature ait été vérifiée : elle doit porter la mention *Notarized
Developer ID* et l'identifiant d'équipe attendu. Un disque notarisé par
quelqu'un d'autre est refusé.

Le remplacement passe par un script détaché : une app ne peut pas se remplacer
elle-même pendant qu'elle s'exécute.

## En cas d'échec

Le workflow s'arrête avec un message précis à chaque étape. Les cas les plus
fréquents :

| Message | Cause |
|---|---|
| `Le secret CERTIFICAT_P12_BASE64 est vide` | Le secret n'est pas enregistré sur le dépôt |
| `Le certificat décodé fait N octets` | Le base64 est tronqué : réexportez et réenregistrez |
| `Aucun certificat Developer ID trouvé` | Le `.p12` ne contient pas de certificat *Developer ID Application* |
| `L'application se déclare en X alors que le tag annonce Y` | `Info.plist` n'a pas été mis à jour, signe d'un problème de workflow |
| Notarisation refusée | Consulter le détail : `xcrun notarytool log <id> --keychain-profile micpin` |
