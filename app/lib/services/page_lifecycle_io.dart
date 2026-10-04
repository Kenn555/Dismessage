/// Native apps have no back/forward cache: nothing to watch.
void watchPageLifecycle({
  required void Function() onLeave,
  required void Function() onReturn,
}) {}
