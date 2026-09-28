function initRideMap(elementId, options) {
  options = options || {};
  const map = L.map(elementId, {
    zoomControl: options.zoomControl !== false,
    attributionControl: options.attributionControl !== false,
    scrollWheelZoom: options.scrollWheelZoom !== false,
  });
  L.tileLayer("https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png", {
    subdomains: "abcd",
    maxZoom: 20,
    attribution:
      '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors &copy; <a href="https://carto.com/attributions">CARTO</a>',
  }).addTo(map);
  return map;
}

// rides: [{ id, label, polyline: [[lat, lon], ...] }, ...]
function drawRoutes(map, rides, options) {
  options = options || {};
  const color = options.color || "#ff9d2e";
  const weight = options.weight || 3;
  const opacity = options.opacity != null ? options.opacity : 0.6;
  const bounds = [];

  rides.forEach(function (ride) {
    if (!ride.polyline || ride.polyline.length < 2) return;
    const line = L.polyline(ride.polyline, { color: color, weight: weight, opacity: opacity }).addTo(map);
    ride.polyline.forEach(function (pt) { bounds.push(pt); });

    if (options.popups && ride.label) {
      line.bindPopup('<a href="/rides/' + ride.id + '">' + ride.label + "</a>");
      line.on("mouseover", function () { line.setStyle({ weight: weight + 2, opacity: 1 }); });
      line.on("mouseout", function () { line.setStyle({ weight: weight, opacity: opacity }); });
    }
  });

  if (bounds.length) {
    map.fitBounds(bounds, options.fitPadding ? { padding: options.fitPadding } : undefined);
  } else if (options.fallbackView) {
    map.setView(options.fallbackView, options.fallbackZoom || 11);
  }
  return bounds;
}
