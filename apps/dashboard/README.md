# Personal OS Dashboard

Dashboard local macOS SwiftUI, sans dépendance réseau. Il lit la base SQLite
WAL et le statut runtime JSON de mac-detective en mode strictement read-only.

## Lancement intégré

La commande recommandée depuis la racine du repository est :

```sh
./scripts/start-personal-os.sh
```

Elle construit les composants si nécessaire, démarre mac-detective et le
Dashboard avec les mêmes chemins, puis nettoie les deux processus sur `Ctrl+C`.

## Lancement direct pendant le développement

```sh
swift run --package-path apps/dashboard
```

Sans variable d'environnement, le dashboard recherche une base
`data/database/mac_detective.sqlite` dans le repository et un fichier
`.mac-detective-runtime-status.json` placé à côté de cette base. Pour une autre
base :

```sh
MAC_DETECTIVE_DATABASE=/chemin/vers/mac_detective.sqlite \
MAC_DETECTIVE_RUNTIME_STATUS=/chemin/vers/.mac-detective-runtime-status.json \
swift run --package-path apps/dashboard
```

Le repository retrye l'ouverture après une absence ou une erreur SQLite
temporaire. Il ne démarre pas mac-detective, ne déclenche aucune maintenance et
ne modifie ni la base ni les fichiers de statut.
