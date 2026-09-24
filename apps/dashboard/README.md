# Personal OS Dashboard

Dashboard local macOS SwiftUI, sans dépendance réseau.

## Lancer

Depuis la racine du dépôt :

```sh
swift run --package-path apps/dashboard
```

Le dashboard recherche par défaut `data/database/mac_detective.sqlite` et le fichier local de statut runtime à côté de cette base.

Pour une base située ailleurs :

```sh
MAC_DETECTIVE_DATABASE=/chemin/vers/mac_detective.sqlite \
MAC_DETECTIVE_RUNTIME_STATUS=/chemin/vers/.mac-detective-runtime-status.json \
swift run --package-path apps/dashboard
```

Le repository est strictement read-only. Le dashboard ne démarre pas mac-detective et ne déclenche ni maintenance ni modification de configuration.
