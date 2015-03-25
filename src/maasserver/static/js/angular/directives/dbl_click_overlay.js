/* Copyright 2015 Canonical Ltd.  This software is licensed under the
 * GNU Affero General Public License version 3 (see the file LICENSE).
 *
 * Double click overlay directive.
 *
 * Provides the ability for a disabled element to still accept the
 * double click event. By default if an element is disabled then it will
 * receive no click events. This overlays the element with another element
 * that will still receive click events.
 */

angular.module('MAAS').run(['$templateCache', function ($templateCache) {
    // Inject the style for the maas-dbl-overlay class. We inject the style
    // instead of placing it in maas-styles.css because it is required for
    // this directive to work at all.
    var styleElement = document.createElement('style');
    styleElement.innerHTML = [
        '.maas-dbl-overlay {',
            'display: inline-block;',
            'position: relative;',
        '}',
        '.maas-dbl-overlay--overlay {',
            'position: absolute;',
            'left: 0;',
            'right: 0;',
            'top: 0;',
            'bottom: 0;',
            '-webkit-touch-callout: none;',
            '-webkit-user-select: none;',
            '-khtml-user-select: none;',
            '-moz-user-select: none;',
            '-ms-user-select: none;',
            'user-select: none;',
        '}'
    ].join('');
    document.body.appendChild(styleElement);

    // Inject the double_click_overlay.html into the template cache.
    $templateCache.put('directive/templates/double_click_overlay.html', [
        '<div class="maas-dbl-overlay">',
            '<span ng-transclude></span>',
            '<div class="maas-dbl-overlay--overlay"></div>',
        '</div>'
    ].join(''));
}]);

angular.module('MAAS').directive('maasDblClickOverlay', function() {
    return {
        restrict: "A",
        transclude: true,
        replace: true,
        scope: {
            maasDblClickOverlay: '&'
        },
        templateUrl: 'directive/templates/double_click_overlay.html',
        link: function(scope, element, attrs) {
            // Create the click function that will be called when the overlay
            // is clicked. This changes based on the element that is
            // transcluded into this directive.
            var overlay = element.find(".maas-dbl-overlay--overlay");
            var transclude = element.find("span[ng-transclude]").children()[0];
            var clickElement;
            if(transclude.tagName === "SELECT") {
                clickElement = function() {
                    // Have to create a custom mousedown event for the
                    // select click to be handled. Using 'click()' or 'focus()'
                    // will not work.
                    var evt = document.createEvent('MouseEvents');
                    evt.initMouseEvent('mousedown', true, true, window);
                    transclude.dispatchEvent(evt);
                };

                // Selects use a pointer for the cursor.
                overlay.css({ cursor: "pointer" });
            } else if(transclude.tagName === "INPUT") {
                clickElement = function() {
                    // An input will become in focus when clicked.
                    angular.element(transclude).focus();
                };

                // Inputs use a text for the cursor.
                overlay.css({ cursor: "text" });
            } else {
                clickElement = function() {
                    // Standard element just call click on that element.
                    angular.element(transclude).click();
                };

                // Don't set cursor on other element types.
            }

            // Add the click and double click handlers.
            var overlayClick = function(evt) {
                clickElement();
                evt.preventDefault();
                evt.stopPropagation();
            };
            var overlayDblClick = function(evt) {
                // Call the double click handler with in the scope.
                scope.$apply(scope.maasDblClickOverlay);
                evt.preventDefault();
                evt.stopPropagation();
            };
            overlay.on("click", overlayClick);
            overlay.on("dblclick", overlayDblClick);

            // Remove the handlers when the scope is destroyed.
            scope.$on("$destroy", function() {
                overlay.off("click", overlayClick);
                overlay.off("dblclick", overlayDblClick);
            });
        }
    };
});
