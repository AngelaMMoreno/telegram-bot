// Quiz Engine
(function() {
    'use strict';

    const cfg = window.QUIZ_CONFIG;
    let state = {
        attemptId: null,
        questions: [],
        currentIdx: 0,
        correct: 0,
        wrong: 0,
        blanks: 0,
        totalOriginal: 0,
        answered: false,
        timer: null,
        timerValue: 0,
        resumed: false,
    };

    const $ = id => document.getElementById(id);

    // ── Start quiz ──
    async function startQuiz() {
        try {
            const res = await fetch('/api/quiz/start', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({
                    mode: cfg.mode,
                    quiz_id: cfg.quizId,
                    simulacro_id: cfg.simulacroId,
                }),
            });
            const data = await res.json();
            if (data.error) {
                showError(data.error);
                return;
            }
            state.attemptId = data.attempt_id;
            state.questions = data.questions;
            state.correct = data.correct || 0;
            state.wrong = data.wrong || 0;
            state.totalOriginal = data.total_original || data.questions.length;
            state.resumed = data.resumed;
            state.currentIdx = 0;

            if (state.questions.length === 0) {
                showError('No hay preguntas disponibles.');
                return;
            }

            $('quizLoading').style.display = 'none';
            $('quizInterface').style.display = 'flex';
            $('quizInterface').style.flexDirection = 'column';
            $('quizInterface').style.minHeight = '100dvh';

            showQuestion();
        } catch (e) {
            showError('Error al cargar el test: ' + e.message);
        }
    }

    function showError(msg) {
        $('quizLoading').style.display = 'none';
        $('quizError').style.display = 'flex';
        $('quizErrorMsg').textContent = msg;
    }

    // ── Show question ──
    function showQuestion() {
        const q = state.questions[state.currentIdx];
        if (!q) {
            finishQuiz();
            return;
        }

        state.answered = false;
        const answeredSoFar = state.correct + state.wrong + state.blanks;
        const questionNum = answeredSoFar + 1;

        $('qCurrent').textContent = questionNum;
        $('qTotal').textContent = state.totalOriginal;
        $('scoreCorrect').textContent = state.correct;
        $('scoreWrong').textContent = state.wrong;
        $('questionNumber').textContent = 'Pregunta ' + questionNum;
        $('questionText').textContent = q.text;

        // Progress bar
        const pct = ((questionNum - 1) / state.totalOriginal * 100);
        $('quizProgressFill').style.width = pct + '%';

        // Check favorite status
        checkFavorite(q.id);

        // Options
        const letters = 'ABCDEFGHIJ';
        const listEl = $('optionsList');
        listEl.innerHTML = '';
        q.options.forEach((opt, idx) => {
            const btn = document.createElement('button');
            btn.className = 'option-btn';
            btn.innerHTML = `
                <span class="option-letter">${letters[idx] || idx + 1}</span>
                <span class="option-text">${escapeHtml(opt)}</span>
            `;
            btn.onclick = () => selectOption(idx, opt, q);
            listEl.appendChild(btn);
        });

        // Hide feedback
        $('questionFeedback').style.display = 'none';
        $('nextBtn').style.display = 'none';
        const skipBtn = $('skipBtn');
        if (skipBtn) skipBtn.style.display = cfg.mode === 'simulacro' ? '' : 'none';

        // Timer
        startTimer();
    }

    function escapeHtml(text) {
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }

    // ── Select option ──
    async function selectOption(idx, optText, q) {
        if (state.answered) return;
        state.answered = true;
        stopTimer();

        const isCorrect = optText === q.correct_text;
        const buttons = $('optionsList').querySelectorAll('.option-btn');

        // Disable all buttons
        buttons.forEach(b => b.classList.add('disabled'));

        // Mark selected
        buttons[idx].classList.add(isCorrect ? 'correct' : 'wrong');

        // Highlight correct answer if wrong
        if (!isCorrect) {
            q.options.forEach((opt, i) => {
                if (opt === q.correct_text) {
                    buttons[i].classList.add('correct');
                }
            });
        }

        // Update score
        if (isCorrect) {
            state.correct++;
        } else {
            state.wrong++;
        }
        $('scoreCorrect').textContent = state.correct;
        $('scoreWrong').textContent = state.wrong;

        // Show feedback
        const fb = $('questionFeedback');
        fb.style.display = '';
        fb.className = 'question-feedback ' + (isCorrect ? 'feedback-correct' : 'feedback-wrong');
        $('feedbackContent').textContent = isCorrect ? 'Correcto!' : 'Incorrecto. La respuesta era: ' + q.correct_text;

        if (q.explicacion) {
            $('feedbackExplanation').style.display = '';
            $('feedbackExplanation').textContent = q.explicacion;
        } else {
            $('feedbackExplanation').style.display = 'none';
        }

        // Send answer to server
        try {
            await fetch('/api/quiz/answer', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({
                    attempt_id: state.attemptId,
                    question_id: q.id,
                    selected_option: optText,
                    correct_text: q.correct_text,
                    mode: cfg.mode,
                }),
            });
        } catch (e) {
            console.error('Error saving answer:', e);
        }

        $('nextBtn').style.display = '';
        const skipBtn = $('skipBtn');
        if (skipBtn) skipBtn.style.display = 'none';

        // Auto-advance after short delay on correct answers
        if (isCorrect && state.currentIdx < state.questions.length - 1) {
            setTimeout(() => {
                if (state.answered && state.currentIdx < state.questions.length - 1) {
                    // Only auto-advance if user hasn't already clicked
                }
            }, 1500);
        }
    }

    // ── Skip (simulacro only) ──
    window.skipQuestion = async function() {
        if (state.answered) return;
        state.answered = true;
        stopTimer();
        state.blanks++;

        const q = state.questions[state.currentIdx];
        try {
            await fetch('/api/quiz/skip', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({
                    attempt_id: state.attemptId,
                    question_id: q.id,
                }),
            });
        } catch (e) {
            console.error('Error skipping:', e);
        }

        // Show correct answer
        const buttons = $('optionsList').querySelectorAll('.option-btn');
        buttons.forEach(b => b.classList.add('disabled'));
        q.options.forEach((opt, i) => {
            if (opt === q.correct_text) {
                buttons[i].classList.add('correct');
            }
        });

        $('nextBtn').style.display = '';
        const skipBtn = $('skipBtn');
        if (skipBtn) skipBtn.style.display = 'none';
    };

    // ── Next question ──
    window.nextQuestion = function() {
        state.currentIdx++;
        if (state.currentIdx >= state.questions.length) {
            finishQuiz();
        } else {
            showQuestion();
        }
    };

    // ── Timer ──
    function startTimer() {
        stopTimer();
        if (!cfg.timerSeconds) {
            $('quizTimer').style.display = 'none';
            return;
        }
        $('quizTimer').style.display = '';
        state.timerValue = cfg.timerSeconds;
        updateTimerDisplay();
        state.timer = setInterval(() => {
            state.timerValue--;
            updateTimerDisplay();
            if (state.timerValue <= 0) {
                stopTimer();
                timeUp();
            }
        }, 1000);
    }

    function stopTimer() {
        if (state.timer) {
            clearInterval(state.timer);
            state.timer = null;
        }
    }

    function updateTimerDisplay() {
        const el = $('quizTimer');
        el.textContent = state.timerValue;
        if (state.timerValue <= 5) {
            el.classList.add('urgent');
        } else {
            el.classList.remove('urgent');
        }
    }

    function timeUp() {
        if (state.answered) return;
        state.answered = true;
        state.wrong++;

        const q = state.questions[state.currentIdx];
        const buttons = $('optionsList').querySelectorAll('.option-btn');
        buttons.forEach(b => b.classList.add('disabled'));

        // Show correct
        q.options.forEach((opt, i) => {
            if (opt === q.correct_text) {
                buttons[i].classList.add('correct');
            }
        });

        $('scoreWrong').textContent = state.wrong;

        const fb = $('questionFeedback');
        fb.style.display = '';
        fb.className = 'question-feedback feedback-wrong';
        $('feedbackContent').textContent = 'Tiempo agotado! La respuesta era: ' + q.correct_text;
        if (q.explicacion) {
            $('feedbackExplanation').style.display = '';
            $('feedbackExplanation').textContent = q.explicacion;
        } else {
            $('feedbackExplanation').style.display = 'none';
        }

        // Record as wrong
        fetch('/api/quiz/answer', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({
                attempt_id: state.attemptId,
                question_id: q.id,
                selected_option: '__timeout__',
                correct_text: q.correct_text,
                mode: cfg.mode,
            }),
        }).catch(e => console.error(e));

        $('nextBtn').style.display = '';
        const skipBtn = $('skipBtn');
        if (skipBtn) skipBtn.style.display = 'none';
    }

    // ── Finish ──
    async function finishQuiz() {
        stopTimer();
        try {
            const res = await fetch('/api/quiz/finish', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({
                    attempt_id: state.attemptId,
                    correct: state.correct,
                    wrong: state.wrong,
                    mode: cfg.mode,
                    simulacro_id: cfg.simulacroId,
                }),
            });
            const data = await res.json();
            sessionStorage.setItem('quizResult', JSON.stringify(data));

            if (cfg.mode === 'simulacro' && data.simulacro) {
                window.location.href = '/simulacro-results';
            } else {
                window.location.href = '/results';
            }
        } catch (e) {
            console.error('Error finishing quiz:', e);
            window.location.href = '/results';
        }
    }

    // ── Favorites ──
    async function checkFavorite(questionId) {
        try {
            const res = await fetch('/api/quiz/is-favorite', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({question_id: questionId}),
            });
            const data = await res.json();
            const btn = $('favBtn');
            const svg = btn.querySelector('svg polygon');
            if (data.favorita) {
                btn.classList.add('active');
                svg.setAttribute('fill', 'currentColor');
            } else {
                btn.classList.remove('active');
                svg.setAttribute('fill', 'none');
            }
        } catch (e) {}
    }

    window.toggleQuestionFav = async function() {
        const q = state.questions[state.currentIdx];
        if (!q) return;
        try {
            const res = await fetch('/api/quiz/toggle-favorite', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({question_id: q.id}),
            });
            const data = await res.json();
            const btn = $('favBtn');
            const svg = btn.querySelector('svg polygon');
            if (data.favorita) {
                btn.classList.add('active');
                svg.setAttribute('fill', 'currentColor');
            } else {
                btn.classList.remove('active');
                svg.setAttribute('fill', 'none');
            }
        } catch (e) {}
    };

    // ── Exit / Discard ──
    window.confirmExit = function() {
        $('exitModal').style.display = 'flex';
    };
    window.closeModal = function() {
        $('exitModal').style.display = 'none';
    };
    window.exitQuiz = function() {
        stopTimer();
        window.location.href = '/';
    };
    window.discardQuiz = async function() {
        stopTimer();
        try {
            await fetch('/api/quiz/discard', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({
                    mode: cfg.mode,
                    quiz_id: cfg.quizId,
                }),
            });
        } catch (e) {}
        window.location.href = '/';
    };

    // ── Init ──
    document.addEventListener('DOMContentLoaded', startQuiz);
})();
