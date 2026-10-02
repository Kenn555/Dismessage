{{flutter_js}}
{{flutter_build_config}}

// Keep the HTML loading screen until the Flutter app is ready to draw.
_flutter.loader.load({
  onEntrypointLoaded: async function (engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine();
    await appRunner.runApp();
    document.getElementById('loading')?.remove();
  },
});
