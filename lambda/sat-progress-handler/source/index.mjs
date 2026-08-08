// SAT progress tracker — practical family version.
// Node.js 20/22 Lambda runtime; AWS SDK v3 is available in the runtime.

import {
  randomUUID,
  timingSafeEqual } from 'node:crypto';
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import {
  DynamoDBDocumentClient,
  GetCommand,
  PutCommand,
  QueryCommand,
  UpdateCommand
} from '@aws-sdk/lib-dynamodb';

import {
  CognitoIdentityProviderClient,
  AdminCreateUserCommand,
  AdminDeleteUserCommand,
  AdminGetUserCommand,
  AdminEnableUserCommand,
  AdminDisableUserCommand,
  AdminSetUserPasswordCommand,
  AdminAddUserToGroupCommand,
  AdminUpdateUserAttributesCommand
} from '@aws-sdk/client-cognito-identity-provider';

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}), {
  marshallOptions: { removeUndefinedValues: true }
});

const cognito = new CognitoIdentityProviderClient({});
const USER_POOL_ID = process.env.USER_POOL_ID || '';
const STUDENT_GROUP = process.env.STUDENT_GROUP || '';

const TABLE = process.env.TABLE_NAME || 'sat-progress';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || '';
const STUDENT_DIRECTORY = '__students__';
const STUDENT_PREFIX = 'student#';

const CORS = {
  'Content-Type': 'application/json'
};

class HttpError extends Error {
  constructor(statusCode, code, message) {
    super(message);
    this.statusCode = statusCode;
    this.code = code;
  }
}

const satEnglishOriginalHandler = async event => {
  const method = event.requestContext?.http?.method || event.httpMethod;
  if (method === 'OPTIONS') return { statusCode: 204, headers: CORS, body: '' };
  if (method !== 'POST') return resp(405, { code: 'METHOD_NOT_ALLOWED', error: 'method not allowed' });

  let body;
  try {
    body = JSON.parse(event.body || '{}');
  } catch {
    return resp(400, { code: 'INVALID_JSON', error: 'invalid JSON' });
  }

  try {
    switch (body.action) {
      case 'record': {
        const userId = requireStudentId(body.userId);
        await requireActiveStudent(userId);
        return resp(200, await recordAttempt({ ...body, userId }));
      }
      case 'progress': {
        const userId = requireStudentId(body.userId);
        await requireActiveStudent(userId);
        return resp(200, await getProgress(userId));
      }
      case 'englishProgress': {
        const userId = requireStudentId(body.userId);
        await requireActiveStudent(userId);
        return resp(200, await getEnglishProgress(userId));
      }
      case 'saveEnglishProgress': {
        const userId = requireStudentId(body.userId);
        await requireActiveStudent(userId);
        return resp(200, await saveEnglishProgress(userId, body.learned));
      }
      case 'getStudent': {
        const userId = requireStudentId(body.userId);
        const student = await getStudent(userId);
        if (!student) throw new HttpError(404, 'STUDENT_NOT_FOUND', 'Student was not found');
        return resp(200, { student });
      }
      // SAT_ADMIN_ACCOUNT_ACTIONS_V1
      case 'createStudentAccount':
        assertAdmin(body.adminPassword);
        return resp(201, await createStudentAccount({
          displayName: body.displayName,
          username: body.username,
          email: body.email
        }));
      case 'adminStudentOverview': {
        assertAdmin(body.adminPassword);
        const studentId = requireStudentId(body.studentId);
        return resp(200, await adminStudentOverview(studentId));
      }
      case 'resendStudentInvitation': {
        assertAdmin(body.adminPassword);
        const studentId = requireStudentId(body.studentId);
        return resp(200, await resendStudentInvitation(studentId));
      }
      case 'resetStudentPassword': {
        assertAdmin(body.adminPassword);
        const studentId = requireStudentId(body.studentId);
        return resp(200, await resetStudentPassword(studentId));
      }
      case 'setStudentActive': {
        assertAdmin(body.adminPassword);
        const studentId = requireStudentId(body.studentId);
        return resp(200, await setStudentActive(studentId, body.active === true));
      }
      case 'createStudent':
        assertAdmin(body.adminPassword);
        return resp(201, { student: await createStudent(body.displayName, body.requestedStudentId) });
      case 'listStudents':
        assertAdmin(body.adminPassword);
        return resp(200, { students: await listStudents() });
      case 'adminProgress': {
        assertAdmin(body.adminPassword);
        const studentId = requireStudentId(body.studentId);
        return resp(200, await getProgress(studentId));
      }
      case 'unlockQuestion': {
        assertAdmin(body.adminPassword);
        const studentId = requireStudentId(body.studentId);
        const questionId = requireQuestionId(body.questionId);
        return resp(200, await unlockQuestion(studentId, questionId));
      }
      default:
        throw new HttpError(400, 'UNKNOWN_ACTION', `unknown action: ${body.action}`);
    }
  } catch (error) {
    if (error instanceof HttpError) {
      return resp(error.statusCode, { code: error.code, error: error.message, message: error.message });
    }
    console.error(error);
    return resp(500, { code: 'INTERNAL_ERROR', error: 'internal error' });
  }
};

function normalizeStudentId(value) {
  const normalized = String(value || '').trim().toLowerCase();
  return /^[a-z0-9_-]{1,80}$/.test(normalized) ? normalized : '';
}

function requireStudentId(value) {
  const studentId = normalizeStudentId(value);
  if (!studentId) throw new HttpError(400, 'INVALID_STUDENT_ID', 'A valid student ID is required');
  return studentId;
}

function requireQuestionId(value) {
  const questionId = String(value || '').trim();
  if (!/^[a-zA-Z0-9_-]{1,100}$/.test(questionId)) {
    throw new HttpError(400, 'INVALID_QUESTION_ID', 'A valid question ID is required');
  }
  return questionId;
}

function assertAdmin(suppliedPassword) {
  if (!ADMIN_PASSWORD) {
    throw new HttpError(503, 'ADMIN_PASSWORD_NOT_CONFIGURED', 'ADMIN_PASSWORD is not configured in Lambda');
  }

  const expected = Buffer.from(ADMIN_PASSWORD);
  const supplied = Buffer.from(String(suppliedPassword || ''));
  if (expected.length !== supplied.length || !timingSafeEqual(expected, supplied)) {
    throw new HttpError(403, 'ADMIN_FORBIDDEN', 'Invalid administrator password');
  }
}

// SAT_MILESTONE_RETRY_V1
function mathQuestionPosition(questionId) {
  const id = String(questionId || '').trim();
  let match = id.match(/^v([1-3])q(\d{3})$/i);
  if (match) return { group: `v${match[1]}q`, setNumber: 1, volumeNumber: Number(match[1]), questionNumber: Number(match[2]), totalQuestions: 100 };
  match = id.match(/^s(\d+)v([1-3])q(\d{3})$/i);
  if (match) return { group: `s${match[1]}v${match[2]}q`, setNumber: Number(match[1]), volumeNumber: Number(match[2]), questionNumber: Number(match[3]), totalQuestions: 100 };
  return null;
}

function firstAttemptTime(item) {
  const time = Date.parse(item?.firstAt || item?.lastAt || '');
  return Number.isFinite(time) ? time : Number.MAX_SAFE_INTEGER;
}

function decorateProgressItems(rawItems) {
  const items = (rawItems || []).map(normalizeProgressItem);
  const groups = new Map();
  items.forEach(item => {
    const position = mathQuestionPosition(item.questionId);
    if (!position) return;
    if (!groups.has(position.group)) groups.set(position.group, { position, items: [] });
    groups.get(position.group).items.push(item);
  });

  const retryPolicy = {};
  groups.forEach(({ position, items: volumeItems }, group) => {
    const sorted = [...volumeItems].sort((left, right) => {
      const timeDifference = firstAttemptTime(left) - firstAttemptTime(right);
      if (timeDifference) return timeDifference;
      return (mathQuestionPosition(left.questionId)?.questionNumber || 999) - (mathQuestionPosition(right.questionId)?.questionNumber || 999);
    });
    const attempted = sorted.length;
    const milestoneUnlocked = Math.min(position.totalQuestions, Math.floor(attempted / 20) * 20);
    const nextMilestone = attempted >= position.totalQuestions ? position.totalQuestions : Math.min(position.totalQuestions, milestoneUnlocked + 20);
    let retryAvailable = 0;

    sorted.forEach((item, index) => {
      const rank = index + 1;
      const attempts = Number(item.attempts || 1);
      const incorrect = item.lastResult === 'incorrect';
      const administratorAllowed = incorrect && (item.storedLocked === false || item.storedCorrectionAllowed === true);
      const autoCorrectionAvailable = incorrect && attempts === 1 && rank <= milestoneUnlocked;
      const correctionAllowed = administratorAllowed || autoCorrectionAvailable;
      item.attemptRank = rank;
      item.milestoneUnlocked = milestoneUnlocked;
      item.nextMilestone = nextMilestone;
      item.autoCorrectionAvailable = autoCorrectionAvailable;
      item.correctionAllowed = correctionAllowed;
      item.correctionSource = administratorAllowed ? 'administrator' : autoCorrectionAvailable ? 'milestone' : null;
      item.locked = item.lastResult === 'correct' ? true : incorrect ? !correctionAllowed : false;
      if (correctionAllowed) retryAvailable += 1;
    });

    retryPolicy[group] = { setNumber: position.setNumber, volumeNumber: position.volumeNumber, totalQuestions: position.totalQuestions, attempted, milestoneUnlocked, nextMilestone, attemptsToNext: Math.max(0, nextMilestone - attempted), retryAvailable };
  });
  return { items, retryPolicy };
}

async function queryVolumeItems(userId, group) {
  const result = await ddb.send(new QueryCommand({
    TableName: TABLE,
    KeyConditionExpression: 'userId = :userId AND begins_with(questionId, :group)',
    ExpressionAttributeValues: { ':userId': userId, ':group': group }
  }));
  return result.Items || [];
}

async function getProgressItem(userId, questionId) {
  const result = await ddb.send(new GetCommand({ TableName: TABLE, Key: { userId, questionId } }));
  return result.Item || null;
}

async function automaticCorrectionAllowed(userId, questionId) {
  const position = mathQuestionPosition(questionId);
  if (!position) return false;
  const rawItems = await queryVolumeItems(userId, position.group);
  const item = decorateProgressItems(rawItems).items.find(candidate => candidate.questionId === questionId);
  return Boolean(item?.autoCorrectionAvailable);
}

async function decoratedProgressItem(userId, item) {
  const position = mathQuestionPosition(item?.questionId);
  if (!position) return normalizeProgressItem(item);
  const rawItems = await queryVolumeItems(userId, position.group);
  return decorateProgressItems(rawItems).items.find(candidate => candidate.questionId === item.questionId) || normalizeProgressItem(item);
}

// BEGIN SHARED_PROGRESS_REPAIR_HELPERS
const SHARED_PROGRESS_REPAIR_BUILD = '20260801-shared-api-repair-v4-20260802T003006Z';
const SAT_RETRY_MILESTONE_SIZE = 20;

function satMathQuestionPosition(questionId) {
  const id = String(questionId || '').trim();

  let match = id.match(/^v([1-3])q(\d{3})$/i);
  if (match) {
    return {
      group: `v${match[1]}q`,
      setNumber: 1,
      volumeNumber: Number(match[1]),
      questionNumber: Number(match[2]),
      totalQuestions: 100
    };
  }

  match = id.match(/^s(\d+)v([1-3])q(\d{3})$/i);
  if (match) {
    return {
      group: `s${match[1]}v${match[2]}q`,
      setNumber: Number(match[1]),
      volumeNumber: Number(match[2]),
      questionNumber: Number(match[3]),
      totalQuestions: 100
    };
  }

  return null;
}

function satProgressFirstTime(item) {
  const time = Date.parse(
    item?.firstAt ||
    item?.lastAt ||
    ''
  );

  return Number.isFinite(time)
    ? time
    : Number.MAX_SAFE_INTEGER;
}

function satNormalizeProgressItem(item) {
  const attempted = Boolean(item?.lastResult);
  const storedLocked =
    typeof item?.locked === 'boolean'
      ? item.locked
      : attempted;
  const storedCorrectionAllowed =
    item?.correctionAllowed === true;

  return {
    ...item,
    attempts: Number(
      item?.attempts || (attempted ? 1 : 0)
    ),
    storedLocked,
    storedCorrectionAllowed,
    locked: storedLocked,
    correctionAllowed:
      attempted &&
      item.lastResult === 'incorrect' &&
      (
        !storedLocked ||
        storedCorrectionAllowed
      )
  };
}

function satDecorateProgressItems(rawItems) {
  const items = (rawItems || []).map(
    satNormalizeProgressItem
  );
  const grouped = new Map();

  for (const item of items) {
    const position =
      satMathQuestionPosition(item.questionId);

    if (!position) continue;

    if (!grouped.has(position.group)) {
      grouped.set(position.group, {
        position,
        items: []
      });
    }

    grouped.get(position.group).items.push(item);
  }

  const retryPolicy = {};

  for (const [group, value] of grouped.entries()) {
    const sorted = [...value.items].sort(
      (left, right) => {
        const timeDifference =
          satProgressFirstTime(left) -
          satProgressFirstTime(right);

        if (timeDifference !== 0) {
          return timeDifference;
        }

        const leftNumber =
          satMathQuestionPosition(
            left.questionId
          )?.questionNumber || 999;
        const rightNumber =
          satMathQuestionPosition(
            right.questionId
          )?.questionNumber || 999;

        return leftNumber - rightNumber;
      }
    );

    const attempted = sorted.length;
    const milestoneUnlocked = Math.min(
      value.position.totalQuestions,
      Math.floor(
        attempted / SAT_RETRY_MILESTONE_SIZE
      ) * SAT_RETRY_MILESTONE_SIZE
    );
    const nextMilestone =
      attempted >= value.position.totalQuestions
        ? value.position.totalQuestions
        : Math.min(
            value.position.totalQuestions,
            milestoneUnlocked +
              SAT_RETRY_MILESTONE_SIZE
          );

    let retryAvailable = 0;

    sorted.forEach((item, index) => {
      const attemptRank = index + 1;
      const incorrect =
        item.lastResult === 'incorrect';
      const administratorAllowed =
        incorrect &&
        (
          item.storedLocked === false ||
          item.storedCorrectionAllowed === true
        );
      const autoCorrectionAvailable =
        incorrect &&
        item.attempts === 1 &&
        attemptRank <= milestoneUnlocked;
      const correctionAllowed =
        administratorAllowed ||
        autoCorrectionAvailable;

      item.attemptRank = attemptRank;
      item.milestoneUnlocked =
        milestoneUnlocked;
      item.nextMilestone = nextMilestone;
      item.attemptsToNext = Math.max(
        0,
        nextMilestone - attempted
      );
      item.autoCorrectionAvailable =
        autoCorrectionAvailable;
      item.correctionAllowed =
        correctionAllowed;
      item.correctionSource =
        administratorAllowed
          ? 'administrator'
          : autoCorrectionAvailable
            ? 'milestone'
            : null;
      item.locked =
        item.lastResult === 'correct'
          ? true
          : incorrect
            ? !correctionAllowed
            : false;

      if (correctionAllowed) {
        retryAvailable += 1;
      }
    });

    retryPolicy[group] = {
      setNumber: value.position.setNumber,
      volumeNumber:
        value.position.volumeNumber,
      totalQuestions:
        value.position.totalQuestions,
      attempted,
      milestoneUnlocked,
      nextMilestone,
      attemptsToNext: Math.max(
        0,
        nextMilestone - attempted
      ),
      retryAvailable
    };
  }

  return {
    items,
    retryPolicy
  };
}

async function satQueryAllProgress(userId) {
  const result = await ddb.send(
    new QueryCommand({
      TableName: TABLE,
      KeyConditionExpression:
        'userId = :userId',
      ExpressionAttributeValues: {
        ':userId': userId
      },
      ConsistentRead: true
    })
  );

  return result.Items || [];
}

async function satQueryVolumeProgress(
  userId,
  group
) {
  const result = await ddb.send(
    new QueryCommand({
      TableName: TABLE,
      KeyConditionExpression:
        'userId = :userId AND ' +
        'begins_with(questionId, :group)',
      ExpressionAttributeValues: {
        ':userId': userId,
        ':group': group
      },
      ConsistentRead: true
    })
  );

  return result.Items || [];
}

async function satGetProgressItem(
  userId,
  questionId
) {
  const result = await ddb.send(
    new GetCommand({
      TableName: TABLE,
      Key: {
        userId,
        questionId
      },
      ConsistentRead: true
    })
  );

  return result.Item || null;
}

async function satIsAutomaticCorrectionAvailable(
  userId,
  questionId
) {
  const position =
    satMathQuestionPosition(questionId);

  if (!position) return false;

  const rawItems =
    await satQueryVolumeProgress(
      userId,
      position.group
    );

  const item =
    satDecorateProgressItems(rawItems)
      .items
      .find(
        candidate =>
          candidate.questionId === questionId
      );

  return Boolean(
    item?.autoCorrectionAvailable
  );
}

async function satDecorateSavedProgressItem(
  userId,
  savedItem
) {
  const position =
    satMathQuestionPosition(
      savedItem?.questionId
    );

  if (!position) {
    return satNormalizeProgressItem(
      savedItem
    );
  }

  const rawItems =
    await satQueryVolumeProgress(
      userId,
      position.group
    );

  return (
    satDecorateProgressItems(rawItems)
      .items
      .find(
        candidate =>
          candidate.questionId ===
          savedItem.questionId
      ) ||
    satNormalizeProgressItem(savedItem)
  );
}
// END SHARED_PROGRESS_REPAIR_HELPERS

async function recordAttempt({
  userId,
  questionId,
  correct,
  choice,
  category
}) {
  const validQuestionId =
    requireQuestionId(questionId);
  const now = new Date().toISOString();
  const existing =
    await satGetProgressItem(
      userId,
      validQuestionId
    );

  let attemptMode = 'first';

  if (existing) {
    const attempts = Number(
      existing.attempts || 1
    );

    if (
      existing.lastResult === 'correct'
    ) {
      throw new HttpError(
        409,
        'QUESTION_LOCKED',
        'This question has already been completed'
      );
    }

    if (existing.locked === false) {
      attemptMode = 'administrator';
    } else if (
      attempts === 1 &&
      await satIsAutomaticCorrectionAvailable(
        userId,
        validQuestionId
      )
    ) {
      attemptMode = 'milestone';
    } else {
      throw new HttpError(
        409,
        'QUESTION_LOCKED',
        attempts > 1
          ? 'The correction attempt is complete; administrator approval is required'
          : 'This question is locked until its 20-question correction milestone'
      );
    }
  }

  const names = {
    '#attempts': 'attempts',
    '#correctCount': 'correctCount',
    '#lastResult': 'lastResult',
    '#lastChoice': 'lastChoice',
    '#lastAt': 'lastAt',
    '#category': 'category',
    '#firstAt': 'firstAt',
    '#locked': 'locked',
    '#correctionAllowed':
      'correctionAllowed',
    '#lastAttemptType':
      'lastAttemptType'
  };

  /*
   * DynamoDB rejects unused ExpressionAttributeValues.
   * First attempts do not use :zero or :incorrect, so add those
   * values only for correction attempts.
   */
  const values = {
    ':one': 1,
    ':correctIncrement':
      correct ? 1 : 0,
    ':result':
      correct ? 'correct' : 'incorrect',
    ':choice': choice ?? null,
    ':now': now,
    ':category':
      category ?? 'unknown',
    ':true': true,
    ':false': false,
    ':attemptMode': attemptMode
  };

  if (attemptMode !== 'first') {
    values[':zero'] = 0;
    values[':incorrect'] = 'incorrect';
  }

  let updateExpression;
  let conditionExpression;

  if (attemptMode === 'first') {
    updateExpression =
      'ADD #attempts :one, ' +
      '#correctCount :correctIncrement ' +
      'SET #lastResult = :result, ' +
      '#lastChoice = :choice, ' +
      '#lastAt = :now, ' +
      '#category = :category, ' +
      '#firstAt = if_not_exists(' +
      '#firstAt, :now), ' +
      '#locked = :true, ' +
      '#correctionAllowed = :false, ' +
      '#lastAttemptType = :attemptMode';

    conditionExpression =
      'attribute_not_exists(#lastResult)';
  } else {
    updateExpression =
      'SET #attempts = ' +
      'if_not_exists(#attempts, :one) + :one, ' +
      '#correctCount = ' +
      'if_not_exists(#correctCount, :zero) + ' +
      ':correctIncrement, ' +
      '#lastResult = :result, ' +
      '#lastChoice = :choice, ' +
      '#lastAt = :now, ' +
      '#category = :category, ' +
      '#firstAt = if_not_exists(' +
      '#firstAt, :now), ' +
      '#locked = :true, ' +
      '#correctionAllowed = :false, ' +
      '#lastAttemptType = :attemptMode';

    conditionExpression =
      attemptMode === 'administrator'
        ? '#lastResult = :incorrect AND ' +
          '#locked = :false'
        : '#lastResult = :incorrect AND ' +
          '(attribute_not_exists(#attempts) ' +
          'OR #attempts = :one)';
  }

  try {
    const result = await ddb.send(
      new UpdateCommand({
        TableName: TABLE,
        Key: {
          userId,
          questionId: validQuestionId
        },
        UpdateExpression:
          updateExpression,
        ConditionExpression:
          conditionExpression,
        ExpressionAttributeNames:
          names,
        ExpressionAttributeValues:
          values,
        ReturnValues: 'ALL_NEW'
      })
    );

    return satDecorateSavedProgressItem(
      userId,
      result.Attributes
    );
  } catch (error) {
    if (
      error?.name ===
      'ConditionalCheckFailedException'
    ) {
      throw new HttpError(
        409,
        'QUESTION_LOCKED',
        'This question is no longer available for another attempt'
      );
    }

    throw error;
  }
}

function normalizeProgressItem(item) {
  const attempted = Boolean(item?.lastResult);
  const storedLocked = typeof item?.locked === 'boolean' ? item.locked : attempted;
  const storedCorrectionAllowed = item?.correctionAllowed === true;
  return {
    ...item,
    attempts: Number(item?.attempts || (attempted ? 1 : 0)),
    storedLocked,
    storedCorrectionAllowed,
    locked: storedLocked,
    correctionAllowed: attempted && item.lastResult === 'incorrect' && (!storedLocked || storedCorrectionAllowed)
  };
}

async function getProgress(userId) {
  const rawItems =
    await satQueryAllProgress(userId);
  const decorated =
    satDecorateProgressItems(rawItems);
  const items = decorated.items;

  const summary = items.reduce(
    (value, item) => {
      const everCorrect =
        Number(
          item.correctCount || 0
        ) > 0;
      const category =
        item.category || 'unknown';

      value.attempted += 1;
      value.totalAttempts += Number(
        item.attempts || 0
      );
      value.totalCorrect += Number(
        item.correctCount || 0
      );
      value.mastered +=
        everCorrect ? 1 : 0;
      value.lockedIncorrect +=
        item.lastResult === 'incorrect' &&
        item.locked
          ? 1
          : 0;
      value.retryAvailable +=
        item.lastResult === 'incorrect' &&
        item.correctionAllowed
          ? 1
          : 0;

      value.byCategory[category] ||= {
        attempted: 0,
        mastered: 0
      };

      value.byCategory[
        category
      ].attempted += 1;

      if (everCorrect) {
        value.byCategory[
          category
        ].mastered += 1;
      }

      return value;
    },
    {
      attempted: 0,
      mastered: 0,
      totalAttempts: 0,
      totalCorrect: 0,
      lockedIncorrect: 0,
      retryAvailable: 0,
      byCategory: {}
    }
  );

  summary.accuracy =
    summary.totalAttempts > 0
      ? +(
          summary.totalCorrect /
          summary.totalAttempts
        ).toFixed(3)
      : 0;

  return {
    items,
    summary,
    retryPolicy:
      decorated.retryPolicy,
    retryBuild:
      SHARED_PROGRESS_REPAIR_BUILD
  };
}

function cleanLearnedWords(values) {
  if (!Array.isArray(values)) {
    throw new HttpError(400, 'INVALID_ENGLISH_PROGRESS', 'learned must be an array');
  }
  return [...new Set(values
    .map(Number)
    .filter(value => Number.isInteger(value) && value >= 1 && value <= 375))]
    .sort((left, right) => left - right);
}

function englishProgressKey(studentId) {
  return {
    userId: `english#${studentId}`,
    questionId: 'vocabulary'
  };
}

async function getEnglishProgress(studentId) {
  const result = await ddb.send(new GetCommand({
    TableName: TABLE,
    Key: englishProgressKey(studentId)
  }));

  const learned = cleanLearnedWords(result.Item?.learned || []);
  return {
    studentId,
    learned,
    learnedCount: learned.length,
    updatedAt: result.Item?.updatedAt || null
  };
}

async function saveEnglishProgress(studentId, values) {
  const learned = cleanLearnedWords(values);
  const now = new Date().toISOString();

  await ddb.send(new UpdateCommand({
    TableName: TABLE,
    Key: englishProgressKey(studentId),
    UpdateExpression:
      'SET #studentId = :studentId, #entityType = :entityType, #learned = :learned, ' +
      '#learnedCount = :learnedCount, #updatedAt = :updatedAt',
    ExpressionAttributeNames: {
      '#studentId': 'studentId',
      '#entityType': 'entityType',
      '#learned': 'learned',
      '#learnedCount': 'learnedCount',
      '#updatedAt': 'updatedAt'
    },
    ExpressionAttributeValues: {
      ':studentId': studentId,
      ':entityType': 'englishVocabularyProgress',
      ':learned': learned,
      ':learnedCount': learned.length,
      ':updatedAt': now
    }
  }));

  return { studentId, learned, learnedCount: learned.length, updatedAt: now };
}

// BEGIN SAT_ADMIN_ACCOUNT_MANAGEMENT_V1
const SAT_ADMIN_MATH_TOTAL = 600;
const SAT_ADMIN_ENGLISH_TOTAL = 375;

function requireUserPool() {
  if (!USER_POOL_ID) {
    throw new HttpError(503, 'USER_POOL_NOT_CONFIGURED',
      'USER_POOL_ID is not configured for student account administration');
  }
  return USER_POOL_ID;
}
// SAT_ADMIN_STUDENT_GROUP_V1
function requireStudentGroup() {
  const group = String(STUDENT_GROUP || '').trim();
  if (!group) {
    throw new HttpError(
      503,
      'STUDENT_GROUP_NOT_CONFIGURED',
      'STUDENT_GROUP is not configured for student account administration'
    );
  }
  return group;
}

async function ensureStudentGroupMembership(studentId) {
  requireUserPool();
  const group = requireStudentGroup();

  try {
    await cognito.send(new AdminAddUserToGroupCommand({
      UserPoolId: USER_POOL_ID,
      Username: studentId,
      GroupName: group
    }));
  } catch (error) {
    if (error?.name === 'ResourceNotFoundException') {
      throw new HttpError(
        503,
        'STUDENT_GROUP_NOT_FOUND',
        `Required Cognito student group "${group}" was not found`
      );
    }
    throw cognitoHttpError(
      error,
      'Unable to assign the student to the Cognito students group'
    );
  }
}

function normalizeEmail(value) {
  const email = String(value || '').trim().toLowerCase();
  if (!email) return '';
  if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    throw new HttpError(400, 'INVALID_EMAIL', 'Enter a valid email address');
  }
  return email;
}
function temporaryStudentPassword() {
  return `Sa7!${randomUUID().replaceAll('-', '').slice(0, 14)}z`;
}
function isSatMathQuestionId(questionId) {
  const match = /^(?:v[123]q|s2v[123]q)(\d{3})$/.exec(String(questionId || ''));
  if (!match) return false;
  const number = Number(match[1]);
  return number >= 1 && number <= 100;
}
function cognitoHttpError(error, fallbackMessage) {
  const name = error?.name || '';
  if (name === 'UsernameExistsException')
    return new HttpError(409, 'LOGIN_ALREADY_EXISTS', 'A login with that username already exists');
  if (name === 'UserNotFoundException')
    return new HttpError(404, 'LOGIN_NOT_FOUND', 'The Cognito login account was not found');
  if (name === 'InvalidPasswordException')
    return new HttpError(400, 'INVALID_TEMPORARY_PASSWORD', error.message || 'The temporary password is invalid');
  if (name === 'InvalidParameterException')
    return new HttpError(400, 'COGNITO_INVALID_PARAMETER', error.message || fallbackMessage);
  return error;
}
async function cognitoAccount(studentId) {
  requireUserPool();
  try {
    const result = await cognito.send(new AdminGetUserCommand({
      UserPoolId: USER_POOL_ID, Username: studentId
    }));
    const attributes = Object.fromEntries(
      (result.UserAttributes || []).map(attribute => [attribute.Name, attribute.Value])
    );
    return {
      username: result.Username || studentId,
      enabled: result.Enabled !== false,
      userStatus: result.UserStatus || null,
      email: attributes.email || null,
      createdAt: result.UserCreateDate || null,
      modifiedAt: result.UserLastModifiedDate || null
    };
  } catch (error) {
    if (error?.name === 'UserNotFoundException') return null;
    throw cognitoHttpError(error, 'Unable to read the Cognito account');
  }
}
// SAT_ADMIN_EMAIL_INVITATIONS_V1
async function requestStudentInvitationEmail({ studentId, temporaryPassword, email }) {
  if (!email) {
    return { requested: false, delivery: 'NONE', email: null, reason: 'NO_EMAIL' };
  }
  try {
    await cognito.send(new AdminCreateUserCommand({
      UserPoolId: USER_POOL_ID,
      Username: studentId,
      TemporaryPassword: temporaryPassword,
      MessageAction: 'RESEND',
      DesiredDeliveryMediums: ['EMAIL']
    }));
    return { requested: true, delivery: 'EMAIL', email };
  } catch (error) {
    console.error(`Unable to request Cognito invitation email for ${studentId}`, error);
    return {
      requested: false,
      delivery: 'EMAIL',
      email,
      reason: error?.name || 'EMAIL_DELIVERY_REQUEST_FAILED',
      message: error?.message || 'Cognito did not accept the invitation request'
    };
  }
}

async function resendStudentInvitation(studentId) {
  requireUserPool();
  const student = await getStudent(studentId);
  if (!student) throw new HttpError(404, 'STUDENT_NOT_FOUND', 'Student was not found');
  const account = await cognitoAccount(studentId);
  if (!account) throw new HttpError(404, 'LOGIN_NOT_FOUND', 'The Cognito login account was not found');
  if (!account.email) throw new HttpError(409, 'EMAIL_NOT_CONFIGURED', 'This student does not have an email address in Cognito');
  if (account.userStatus !== 'FORCE_CHANGE_PASSWORD') {
    throw new HttpError(409, 'INVITATION_NOT_APPLICABLE', 'Invitation resend is available only before the student completes first login');
  }
  await ensureStudentGroupMembership(studentId);

  const displayName =
    String(
      student.displayName ||
      studentId
    ).trim() || studentId;

  await cognito.send(
    new AdminUpdateUserAttributesCommand({
      UserPoolId: USER_POOL_ID,
      Username: studentId,
      UserAttributes: [{
        Name: 'name',
        Value: displayName
      }]
    })
  );
  const temporaryPassword = temporaryStudentPassword();
  const invitation = await requestStudentInvitationEmail({ studentId, temporaryPassword, email: account.email });
  return { studentId, temporaryPassword, email: account.email, invitation, account: await cognitoAccount(studentId) };
}

async function createStudentAccount({ displayName, username, email }) {
  requireUserPool();
  const studentId = requireStudentId(username);
  const cleanDisplayName = String(displayName || '').trim();
  if (!cleanDisplayName || cleanDisplayName.length > 80) {
    throw new HttpError(400, 'INVALID_DISPLAY_NAME', 'Student name must be between 1 and 80 characters');
  }
  const cleanEmail = normalizeEmail(email);
  if (await getStudent(studentId)) {
    throw new HttpError(409, 'STUDENT_ALREADY_EXISTS', 'A student with that username already exists');
  }
  if (await cognitoAccount(studentId)) {
    throw new HttpError(409, 'LOGIN_ALREADY_EXISTS', 'A Cognito login with that username already exists');
  }
  const temporaryPassword = temporaryStudentPassword();
  const attributes = [
    {
      Name: 'name',
      Value: cleanDisplayName
    },
    ...(
      cleanEmail
        ? [{
            Name: 'email',
            Value: cleanEmail
          }]
        : []
    )
  ];
  try {
    await cognito.send(new AdminCreateUserCommand({
      UserPoolId: USER_POOL_ID,
      Username: studentId,
      TemporaryPassword: temporaryPassword,
      MessageAction: 'SUPPRESS',
      UserAttributes: attributes
    }));
  } catch (error) {
    throw cognitoHttpError(error, 'Unable to create the Cognito login');
  }
  try {
    await ensureStudentGroupMembership(studentId);
  } catch (error) {
    try {
      await cognito.send(new AdminDeleteUserCommand({ UserPoolId: USER_POOL_ID, Username: studentId }));
    } catch (cleanupError) {
      console.error('Unable to clean up Cognito user after group-assignment failure', cleanupError);
    }
    throw error;
  }
  let student;
  try {
    student = await createStudent(cleanDisplayName, studentId);
  } catch (error) {
    try {
      await cognito.send(new AdminDeleteUserCommand({ UserPoolId: USER_POOL_ID, Username: studentId }));
    } catch (cleanupError) {
      console.error('Unable to clean up Cognito user after directory failure', cleanupError);
    }
    throw error;
  }
  const invitation = await requestStudentInvitationEmail({
    studentId,
    temporaryPassword,
    email: cleanEmail
  });
  return {
    student,
    temporaryPassword,
    invitationEmailRequested: invitation.requested,
    invitation,
    account: await cognitoAccount(studentId)
  };
}
async function resetStudentPassword(studentId) {
  requireUserPool();
  const student = await getStudent(studentId);
  if (!student) throw new HttpError(404, 'STUDENT_NOT_FOUND', 'Student was not found');
  const temporaryPassword = temporaryStudentPassword();
  try {
    await cognito.send(new AdminSetUserPasswordCommand({
      UserPoolId: USER_POOL_ID, Username: studentId,
      Password: temporaryPassword, Permanent: false
    }));
  } catch (error) {
    throw cognitoHttpError(error, 'Unable to reset the student password');
  }
  return { studentId, temporaryPassword, account: await cognitoAccount(studentId) };
}
async function setStudentActive(studentId, active) {
  requireUserPool();
  const student = await getStudent(studentId);
  if (!student) throw new HttpError(404, 'STUDENT_NOT_FOUND', 'Student was not found');
  const account = await cognitoAccount(studentId);
  if (!account) throw new HttpError(409, 'LOGIN_NOT_PROVISIONED',
    'This student does not have a Cognito login account yet');
  try {
    await cognito.send(active
      ? new AdminEnableUserCommand({UserPoolId:USER_POOL_ID,Username:studentId})
      : new AdminDisableUserCommand({UserPoolId:USER_POOL_ID,Username:studentId}));
  } catch (error) {
    throw cognitoHttpError(error, 'Unable to change the Cognito account status');
  }
  const now = new Date().toISOString();
  try {
    await ddb.send(new UpdateCommand({
      TableName: TABLE,
      Key: {userId:STUDENT_DIRECTORY,questionId:`${STUDENT_PREFIX}${studentId}`},
      UpdateExpression:'SET #active = :active, #updatedAt = :updatedAt',
      ExpressionAttributeNames:{'#active':'active','#updatedAt':'updatedAt'},
      ExpressionAttributeValues:{':active':active,':updatedAt':now},
      ConditionExpression:'attribute_exists(userId)'
    }));
  } catch (error) {
    try {
      await cognito.send(active
        ? new AdminDisableUserCommand({UserPoolId:USER_POOL_ID,Username:studentId})
        : new AdminEnableUserCommand({UserPoolId:USER_POOL_ID,Username:studentId}));
    } catch (rollbackError) {
      console.error('Unable to roll back Cognito account state', rollbackError);
    }
    throw error;
  }
  return { studentId, active, account: await cognitoAccount(studentId) };
}
async function adminStudentOverview(studentId) {
  const [progress, english, account] = await Promise.all([
    getProgress(studentId), getEnglishProgress(studentId), cognitoAccount(studentId)
  ]);
  const mathItems = (progress.items || []).filter(item => isSatMathQuestionId(item.questionId));
  const attempted = mathItems.filter(item =>
    item.lastResult === 'correct' || item.lastResult === 'incorrect').length;
  const mastered = mathItems.filter(item =>
    Number(item.correctCount || 0) > 0 || item.lastResult === 'correct').length;
  const awaitingCorrections = mathItems.filter(item =>
    item.lastResult === 'incorrect' && item.locked !== false &&
    item.correctionAllowed !== true).length;
  return {
    studentId, account,
    math:{mastered,attempted,total:SAT_ADMIN_MATH_TOTAL,awaitingCorrections},
    english:{
      learned:Array.isArray(english.learned)?english.learned.length:Number(english.learnedCount||0),
      total:SAT_ADMIN_ENGLISH_TOTAL
    }
  };
}
// END SAT_ADMIN_ACCOUNT_MANAGEMENT_V1

async function createStudent(displayNameValue, requestedStudentIdValue) {
  const displayName = String(displayNameValue || '').trim();
  if (!displayName || displayName.length > 80) {
    throw new HttpError(400, 'INVALID_DISPLAY_NAME', 'Student name must be between 1 and 80 characters');
  }

  const requested = String(requestedStudentIdValue || '').trim();
  const studentId = requested
    ? requireStudentId(requested)
    : `st_${randomUUID().replaceAll('-', '').slice(0, 16)}`;
  const now = new Date().toISOString();

  const student = {
    userId: STUDENT_DIRECTORY,
    questionId: `${STUDENT_PREFIX}${studentId}`,
    entityType: 'student',
    studentId,
    displayName,
    active: true,
    createdAt: now,
    updatedAt: now
  };

  try {
    await ddb.send(new PutCommand({
      TableName: TABLE,
      Item: student,
      ConditionExpression: 'attribute_not_exists(userId) AND attribute_not_exists(questionId)'
    }));
  } catch (error) {
    if (error?.name === 'ConditionalCheckFailedException') {
      throw new HttpError(409, 'STUDENT_ALREADY_EXISTS', 'A student with that ID already exists');
    }
    throw error;
  }

  return publicStudent(student);
}

async function listStudents() {
  const result = await ddb.send(new QueryCommand({
    TableName: TABLE,
    KeyConditionExpression: 'userId = :directory AND begins_with(questionId, :prefix)',
    ExpressionAttributeValues: {
      ':directory': STUDENT_DIRECTORY,
      ':prefix': STUDENT_PREFIX
    }
  }));

  return (result.Items || [])
    .map(publicStudent)
    .sort((left, right) => left.displayName.localeCompare(right.displayName));
}

async function getStudent(studentId) {
  const result = await ddb.send(new GetCommand({
    TableName: TABLE,
    Key: {
      userId: STUDENT_DIRECTORY,
      questionId: `${STUDENT_PREFIX}${studentId}`
    }
  }));

  return result.Item ? publicStudent(result.Item) : null;
}

async function requireActiveStudent(studentId) {
  const student = await getStudent(studentId);

  if (!student) {
    throw new HttpError(
      404,
      'STUDENT_NOT_FOUND',
      'This student link was not created by the administrator'
    );
  }

  if (!student.active) {
    throw new HttpError(
      403,
      'STUDENT_INACTIVE',
      'This student link is inactive'
    );
  }

  return student;
}

function publicStudent(item) {
  return {
    studentId: item.studentId,
    displayName: item.displayName,
    active: item.active !== false,
    createdAt: item.createdAt,
    updatedAt: item.updatedAt
  };
}

async function unlockQuestion(studentId, questionId) {
  const now = new Date().toISOString();

  try {
    const result = await ddb.send(new UpdateCommand({
      TableName: TABLE,
      Key: { userId: studentId, questionId },
      UpdateExpression: 'SET #locked = :false, #correctionAllowed = :true, #unlockedAt = :now',
      ConditionExpression: '#lastResult = :incorrect',
      ExpressionAttributeNames: {
        '#locked': 'locked',
        '#correctionAllowed': 'correctionAllowed',
        '#unlockedAt': 'unlockedAt',
        '#lastResult': 'lastResult'
      },
      ExpressionAttributeValues: {
        ':false': false,
        ':true': true,
        ':now': now,
        ':incorrect': 'incorrect'
      },
      ReturnValues: 'ALL_NEW'
    }));

    return normalizeProgressItem(result.Attributes);
  } catch (error) {
    if (error?.name === 'ConditionalCheckFailedException') {
      throw new HttpError(409, 'NOT_UNLOCKABLE', 'Only an incorrectly answered question can be unlocked');
    }
    throw error;
  }
}

function resp(statusCode, body) {
  return { statusCode, headers: CORS, body: JSON.stringify(body) };
}

// BEGIN SAT_ENGLISH_PROGRESS_V6
const SAT_ENGLISH_PROGRESS_ROW = '__english_words__';
const SAT_ENGLISH_TOTAL_WORDS = 375;

function satEnglishNormalizeStudent(value) {
  const id = String(value || '').trim().toLowerCase();
  return /^[a-z0-9_-]{1,80}$/.test(id) ? id : '';
}

function satEnglishNormalizeLearned(values) {
  return [...new Set((Array.isArray(values) ? values : [])
    .map(Number)
    .filter(number =>
      Number.isInteger(number) &&
      number >= 1 &&
      number <= SAT_ENGLISH_TOTAL_WORDS
    ))].sort((left, right) => left - right);
}

function satEnglishParseBody(event) {
  if (!event || typeof event !== 'object') return {};
  if (!Object.prototype.hasOwnProperty.call(event, 'body')) return event;
  let raw = event.body;
  if (event.isBase64Encoded && typeof raw === 'string') {
    raw = Buffer.from(raw, 'base64').toString('utf8');
  }
  if (raw && typeof raw === 'object') return raw;
  if (typeof raw !== 'string' || !raw.trim()) return {};
  try {
    return JSON.parse(raw);
  } catch (_) {
    return {};
  }
}

function satEnglishResponse(statusCode, payload) {
  return {
    statusCode,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'content-type,authorization',
      'Access-Control-Allow-Methods': 'POST,OPTIONS',
      'Cache-Control': 'no-store'
    },
    body: JSON.stringify(payload)
  };
}

function satEnglishRequestLearned(body) {
  return satEnglishNormalizeLearned(
    body.learned ??
    body.learnedWords ??
    body.words ??
    body.progress?.learned ??
    []
  );
}

async function satEnglishSaveProgress(body) {
  const userId = satEnglishNormalizeStudent(
    body.userId || body.studentId || body.student
  );
  if (!userId) {
    return satEnglishResponse(400, {
      error: 'STUDENT_REQUIRED',
      message: 'A valid student ID is required.'
    });
  }

  const learned = satEnglishRequestLearned(body);
  const updatedAt = new Date().toISOString();

  await ddb.send(new UpdateCommand({
    TableName: TABLE,
    Key: {
      userId,
      questionId: SAT_ENGLISH_PROGRESS_ROW
    },
    UpdateExpression:
      'SET #learned = :learned, #updatedAt = :updatedAt, #category = :category',
    ExpressionAttributeNames: {
      '#learned': 'learned',
      '#updatedAt': 'updatedAt',
      '#category': 'category'
    },
    ExpressionAttributeValues: {
      ':learned': learned,
      ':updatedAt': updatedAt,
      ':category': 'english-vocabulary'
    }
  }));

  return satEnglishResponse(200, {
    ok: true,
    studentId: userId,
    learned,
    updatedAt
  });
}

async function satEnglishReadProgress(body) {
  const userId = satEnglishNormalizeStudent(
    body.userId || body.studentId || body.student
  );
  if (!userId) {
    return satEnglishResponse(400, {
      error: 'STUDENT_REQUIRED',
      message: 'A valid student ID is required.'
    });
  }

  const result = await ddb.send(new GetCommand({
    TableName: TABLE,
    Key: {
      userId,
      questionId: SAT_ENGLISH_PROGRESS_ROW
    },
    ConsistentRead: true
  }));

  return satEnglishResponse(200, {
    ok: true,
    studentId: userId,
    learned: satEnglishNormalizeLearned(result.Item?.learned),
    updatedAt: result.Item?.updatedAt || null
  });
}

export const handler = async (event, context) => {
  if (event?.requestContext?.http?.method === 'OPTIONS') {
    return satEnglishResponse(204, {});
  }

  const body = satEnglishParseBody(event);
  const action = String(body.action || '').trim();

  try {
    if (action === 'saveEnglishProgress') {
      return await satEnglishSaveProgress(body);
    }
    if (action === 'englishProgress') {
      return await satEnglishReadProgress(body);
    }
    return await satEnglishOriginalHandler(event, context);
  } catch (error) {
    console.error('SAT English progress v6 error', error);
    return satEnglishResponse(500, {
      error: 'ENGLISH_PROGRESS_ERROR',
      message: error?.message || 'Unable to save English progress.'
    });
  }
};
// END SAT_ENGLISH_PROGRESS_V6
