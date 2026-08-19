# MiddleClick

Utilitaire de barre de menu macOS : clic gauche + droite simultané sur une
Magic Mouse -> vrai clic (et glissé maintenu) du bouton du milieu, pensé
pour un usage type navigation 3D / CAD (Fusion 360...), pas juste un clic
bref.

## Pourquoi cette architecture (2e version)

Une première version se basait uniquement sur `CGEventTap` (intercepter
`leftMouseDown`/`rightMouseDown` et voir s'ils arrivaient en même temps).
Ça ne fonctionne pas : le firmware de la Magic Mouse ne rapporte **jamais**
gauche et droite enfoncés simultanément au niveau des événements système —
il choisit toujours l'un ou l'autre. En revanche, le capteur tactile brut
(via `MultitouchSupport.framework`, privé) voit bien 2 doigts distincts.

Cette version utilise donc :
- **`TouchGate.swift`** : lit le flux tactile brut, compte les doigts posés,
  expose un état `isOpen` (2 doigts = ouvert, par défaut) lu de façon
  synchrone — voir plus bas pourquoi ce n'est plus un système de callback.
- **`MultitouchPrivate.swift`** : chargement dynamique (dlopen) de l'API
  privée `MultitouchSupport.framework` — pas de header officiel, structures
  reconstruites par convention communautaire. **C'est la partie la plus
  fragile du projet.**
- **`MiddleClickEngine.swift`** : le `CGEventTap`, avec un principe de
  **verrouillage à l'appui** — voir ci-dessous.

### Verrouillage à l'appui (3e révision)

Une version intermédiaire réagissait en temps réel à chaque changement du
portillon tactile, y compris en cours de geste ("hot-swap" : convertir un
clic déjà en cours si un 2e doigt apparaissait). Deux problèmes symétriques
sont apparus à l'usage :
- un doigt posé par inadvertance pendant un glissement gauche (sélection en
  cours) annulait la sélection à tort ;
- inversement, un doigt qui se relève pendant un vrai drag milieu coupait le
  drag milieu à tort, alors qu'on veut qu'il continue tant que le bouton
  physique reste enfoncé.

La version actuelle ne regarde le portillon tactile qu'une seule fois, à
l'instant précis du `mouseDown` : si ≥ 2 doigts sont posés à cet instant,
toute la pression (down / dragged / up) est verrouillée en clic milieu
jusqu'au relâchement réel du bouton — les doigts peuvent ensuite se poser ou
se lever sans rien changer. C'est plus simple et plus robuste que réagir en
continu.

Aucun délai artificiel sur la transmission des événements : tout est
transmis en temps réel, sauf pendant une session verrouillée en milieu.

## Compilation

```bash
cd MiddleClick
swift run
```

Pour un usage quotidien stable (permissions macOS liées au chemin du
binaire), construis un vrai `.app` :

```bash
./build_app.sh
open build/MiddleClick.app
```

Le script compile en mode release, assemble `build/MiddleClick.app`
(`Info.plist` avec `LSUIElement` pour rester invisible du Dock) et le
signe en ad-hoc pour lui donner une identité stable — indispensable pour
que macOS retienne les autorisations Accessibilité / Surveillance des
saisies d'une fois sur l'autre, contrairement à `swift run` dont le
chemin du binaire change à chaque build.

Pour lancer l'app automatiquement à la connexion, ajoute
`build/MiddleClick.app` dans Réglages Système > Général > Ouverture >
Ouvrir à la connexion.

L'icône de l'app (Finder/Dock) est dans `AppIcon.iconset/` — le script la
convertit automatiquement en `.icns` via `iconutil` (outil natif macOS).

## Autorisations macOS

- **Accessibilité** (Réglages Système > Confidentialité et sécurité).
- **Surveillance des saisies (Input Monitoring)**, pour le `CGEventTap`.
- `MultitouchSupport` ne semble pas demander d'autorisation séparée au-delà
  de l'Accessibilité, d'après les projets communautaires équivalents.

## Activer / désactiver

Le menu de la barre de menu propose "Désactiver" / "Activer" : l'icône
passe en gris avec une croix superposée quand c'est désactivé (le tap reste
en place, mais laisse tout passer sans y toucher — pas besoin de redonner
les autorisations en réactivant).

## Calibrage / debug

L'app affiche des traces en continu dans le Terminal si tu la lances avec :

```bash
MIDDLECLICK_VERBOSE=1 swift run
```

- `doigts actifs = N (états bruts: [...], tailles brutes: [...])` à chaque
  changement de nombre de doigts détectés. Si le portillon se déclenche
  trop souvent (faux positifs au repos de la main) ou pas assez :
  - ajuste `TouchGate.activeStates` en te basant sur les états bruts observés ;
  - ou augmente `TouchGate.minimumContactSize` en te basant sur les tailles
    brutes observées — un vrai doigt posé donne une taille nettement plus
    grande qu'un effleurement léger. 0 par défaut (pas de filtrage).
  - et/ou ajuste `TouchGate.threshold` (2 par défaut).
- Si un simple clic gauche/droit avec un léger glissement se transforme par
  erreur en clic milieu, augmente `TouchGate.openConfirmDelay` (0.05s par
  défaut) — le portillon exige que 2 doigts soient vus pendant toute cette
  durée avant de s'ouvrir, ce qui filtre les blips d'une seule frame.
- `🟢 ... session verrouillée en clic milieu` / `🔴 ... fin de la session
  milieu verrouillée` : montrent quand une pression est verrouillée en
  clic milieu, et quand elle se termine.

## Limites connues

- Structures `MultitouchSupport` non documentées officiellement : stables
  depuis des années dans la communauté, mais non garanties par Apple, et
  non testables dans l'environnement où ce code a été écrit (pas de Mac
  disponible ici). Si le comptage de doigts semble incohérent, commence par
  regarder les traces `états bruts`.
- Le calcul du nombre de doigts prend le maximum sur tous les périphériques
  multitouch détectés (trackpad intégré compris) : poser 2 doigts sur le
  trackpad pendant un clic sur la souris pourrait déclencher une fusion par
  erreur. Cas limite, à corriger en filtrant par périphérique si besoin.
