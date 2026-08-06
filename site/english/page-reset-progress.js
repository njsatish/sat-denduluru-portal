(() => {
  'use strict';

  function pageNumbers() {
    return [...new Set(
      [...document.querySelectorAll('[data-word-number]')]
        .map(node => Number(node.dataset.wordNumber))
        .filter(number =>
          Number.isInteger(number) &&
          number >= 1 &&
          number <= 375
        )
    )].sort((a, b) => a - b);
  }

  function initialize() {
    const button = document.getElementById('resetProgress');
    const numbers = pageNumbers();

    // Apply only to dedicated 25-word vocabulary pages.
    if (!button || numbers.length !== 25) return;

    const start = numbers[0];
    const end = numbers[numbers.length - 1];

    button.textContent = 'Reset this page';
    button.dataset.resetScope = 'current-page';
    button.title =
      `Clears only words ${start}–${end}. ` +
      'Other English pages are preserved.';
    button.setAttribute(
      'aria-label',
      `Reset progress for words ${start} through ${end}`
    );

    document.addEventListener('click', event => {
      const clicked = event.target.closest?.('#resetProgress');
      if (!clicked) return;

      // Prevent the older "reset all 375" listener from running.
      event.preventDefault();
      event.stopPropagation();
      event.stopImmediatePropagation();

      const confirmed = window.confirm(
        `Reset learned-word progress for words ${start}–${end} ` +
        'on this page?\n\nProgress on all other English pages ' +
        'will remain unchanged.'
      );

      if (!confirmed) return;

      try {
        if (
          typeof window.getProgress !== 'function' ||
          typeof window.setProgress !== 'function'
        ) {
          throw new Error('English progress functions are unavailable.');
        }

        const pageSet = new Set(numbers);
        const current = window.getProgress();

        const retained = (current.learned || [])
          .map(Number)
          .filter(number =>
            Number.isInteger(number) &&
            !pageSet.has(number)
          );

        // Existing setProgress() saves locally and queues cloud sync.
        window.setProgress({ learned: retained });

        if (typeof window.refreshStudyPage === 'function') {
          window.refreshStudyPage();
        } else {
          window.location.reload();
          return;
        }

        clicked.textContent = 'Page reset';
        clicked.disabled = true;

        window.setTimeout(() => {
          clicked.textContent = 'Reset this page';
          clicked.disabled = false;
        }, 1500);
      } catch (error) {
        console.error('Page reset failed', error);
        window.alert(
          'The page progress could not be reset. ' +
          'Refresh the page and try again.'
        );
      }
    }, true);
  }

  if (document.readyState === 'loading') {
    document.addEventListener(
      'DOMContentLoaded',
      initialize,
      { once: true }
    );
  } else {
    initialize();
  }
})();
