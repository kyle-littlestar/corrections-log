import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import {
  DynamoDBDocumentClient,
  PutCommand,
  QueryCommand,
  DeleteCommand,
  UpdateCommand,
} from "@aws-sdk/lib-dynamodb";

const client = new DynamoDBClient({});
const ddb = DynamoDBDocumentClient.from(client);

const TABLE = process.env.TABLE_NAME || "corrections-log-entries";
const USER_ID = "default"; // fixed user for now; swap for auth later

const headers = {
  "Content-Type": "application/json",
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET,POST,PUT,DELETE,OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};

function response(statusCode, body) {
  return { statusCode, headers, body: JSON.stringify(body) };
}

export const handler = async (event) => {
  const method = event.requestContext?.http?.method || event.httpMethod;
  const path = event.rawPath || event.path || "";

  // Extract ID from path: /entries/{id}
  const pathParts = path.replace(/^\//, "").split("/");
  const entryId = pathParts.length > 1 ? decodeURIComponent(pathParts[1]) : null;

  try {
    switch (method) {
      case "OPTIONS":
        return response(200, {});

      case "GET":
        return await getEntries();

      case "POST":
        return await createEntry(JSON.parse(event.body));

      case "PUT":
        if (!entryId) return response(400, { error: "Missing entry ID" });
        return await updateEntry(entryId, JSON.parse(event.body));

      case "DELETE":
        if (!entryId) return response(400, { error: "Missing entry ID" });
        return await deleteEntry(entryId);

      default:
        return response(405, { error: `Method ${method} not allowed` });
    }
  } catch (err) {
    console.error("Handler error:", err);
    return response(500, { error: "Internal server error" });
  }
};

// ── GET /entries — return all entries for this user ──
async function getEntries() {
  const result = await ddb.send(
    new QueryCommand({
      TableName: TABLE,
      KeyConditionExpression: "userId = :uid",
      ExpressionAttributeValues: { ":uid": USER_ID },
    })
  );
  return response(200, result.Items || []);
}

// ── POST /entries — create a new entry ──
async function createEntry(body) {
  if (!body || !body.id) {
    return response(400, { error: "Request body must include 'id'" });
  }

  const item = {
    userId: USER_ID,
    ...body,
    createdAt: body.createdAt || new Date().toISOString(),
    updatedAt: new Date().toISOString(),
  };

  await ddb.send(new PutCommand({ TableName: TABLE, Item: item }));
  return response(201, item);
}

// ── PUT /entries/{id} — update an existing entry ──
async function updateEntry(id, body) {
  if (!body || Object.keys(body).length === 0) {
    return response(400, { error: "Request body cannot be empty" });
  }

  // Build dynamic update expression from body fields
  const reserved = new Set(["userId", "id"]);
  const exprParts = [];
  const exprNames = {};
  const exprValues = {};

  // Always set updatedAt
  body.updatedAt = new Date().toISOString();

  for (const [key, value] of Object.entries(body)) {
    if (reserved.has(key)) continue;
    const nameToken = `#f_${key}`;
    const valueToken = `:v_${key}`;
    exprParts.push(`${nameToken} = ${valueToken}`);
    exprNames[nameToken] = key;
    exprValues[valueToken] = value;
  }

  if (exprParts.length === 0) {
    return response(400, { error: "No updatable fields provided" });
  }

  const result = await ddb.send(
    new UpdateCommand({
      TableName: TABLE,
      Key: { userId: USER_ID, id },
      UpdateExpression: `SET ${exprParts.join(", ")}`,
      ExpressionAttributeNames: exprNames,
      ExpressionAttributeValues: exprValues,
      ReturnValues: "ALL_NEW",
    })
  );

  return response(200, result.Attributes);
}

// ── DELETE /entries/{id} — remove an entry ──
async function deleteEntry(id) {
  await ddb.send(
    new DeleteCommand({
      TableName: TABLE,
      Key: { userId: USER_ID, id },
    })
  );
  return response(200, { deleted: id });
}
