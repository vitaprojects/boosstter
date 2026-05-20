import { Router } from "express";

import { getDashboard } from "../controllers/dashboardController.js";
import {
  createUser,
  listUsers,
  upsertProviderSettings,
} from "../controllers/usersController.js";
import {
  createRequest,
  listRequests,
  updateRequestStage,
} from "../controllers/requestsController.js";
import { createMessage, listMessages } from "../controllers/messagesController.js";
import { createReview } from "../controllers/reviewsController.js";

export const adminRoutes = Router();

adminRoutes.get("/dashboard", getDashboard);
adminRoutes.get("/users", listUsers);
adminRoutes.post("/users", createUser);
adminRoutes.put("/users/:userId/provider-settings", upsertProviderSettings);

adminRoutes.get("/requests", listRequests);
adminRoutes.post("/requests", createRequest);
adminRoutes.patch("/requests/:id/stage", updateRequestStage);

adminRoutes.get("/requests/:requestId/messages", listMessages);
adminRoutes.post("/requests/:requestId/messages", createMessage);
adminRoutes.post("/requests/:requestId/reviews", createReview);
