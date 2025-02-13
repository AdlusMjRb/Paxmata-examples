const WebSocket = require("ws");
const jwt = require("jsonwebtoken");
const url = require("url");
const Project = require("./models/Project");
const Chat = require("./models/Chat");
const ProjectStatsCalculator = require("./services/ProjectStatsCalculator");
const SCORSProcessor = require("./services/SCORSProcessor");

const userConnections = {};
const projectSubscriptions = new Map();

const getUserIdFromRequest = (req) => {
  const parsedUrl = url.parse(req.url, true);
  const token = parsedUrl.query.token;
  if (!token) return null;

  try {
    const decoded = jwt.verify(token, process.env.JWT_SECRET);
    return decoded.id;
  } catch (err) {
    console.error("Invalid token in WebSocket connection:", err);
    return null;
  }
};

const getUserConnections = (userId) => {
  return userConnections[userId.toString()] || [];
};

const handleChatEvents = (ws, userId) => {
  ws.on("message", async (data) => {
    try {
      const message = JSON.parse(data);

      switch (message.type) {
        case "joinProjectChat": {
          if (!projectSubscriptions.has(message.projectId)) {
            projectSubscriptions.set(message.projectId, new Set());
          }
          projectSubscriptions.get(message.projectId).add(userId);

          ws.send(
            JSON.stringify({
              type: "joinedChat",
              projectId: message.projectId,
            })
          );
          break;
        }

        case "sendMessage": {
          const { projectId, content, isAIMessage, clientId } = message;

          const chatMessage = {
            sender: userId,
            content,
            isAIMessage,
            timestamp: new Date(),
          };

          // Save to database
          await Chat.findOneAndUpdate(
            { projectId },
            {
              $push: { messages: chatMessage },
              $set: { lastActivity: new Date() },
              $addToSet: { participants: userId },
            },
            { upsert: true }
          );

          // Broadcast to all users in the project chat
          const subscribers = projectSubscriptions.get(projectId) || new Set();
          for (const subscriberId of subscribers) {
            const connections = getUserConnections(subscriberId);
            connections.forEach((conn) => {
              if (conn.readyState === WebSocket.OPEN) {
                conn.send(
                  JSON.stringify({
                    type: "newMessage",
                    projectId,
                    message: {
                      ...chatMessage,
                      clientId: clientId || null,
                    },
                  })
                );
              }
            });
          }
          break;
        }

        case "leaveProjectChat": {
          if (projectSubscriptions.has(message.projectId)) {
            projectSubscriptions.get(message.projectId).delete(userId);
          }
          break;
        }
        case "CONTRACT_GENERATED": {
          const { projectOwnerId, developerId, contractDetails } = message;
          await notifyContractGenerated(
            projectOwnerId,
            developerId,
            contractDetails
          );
          break;
        }
      }
    } catch (error) {
      console.error("Chat event error:", error);
      ws.send(
        JSON.stringify({
          type: "error",
          message: "Failed to process message",
        })
      );
    }
  });
};

const initWebSocket = (server) => {
  const wss = new WebSocket.Server({
    server,
    path: "/ws",
  });

  wss.on("connection", (ws, req) => {
    console.log("Client connected to WebSocket");
    ws.isAlive = true;

    // Set up ping/pong heartbeat
    ws.on("pong", () => {
      ws.isAlive = true;
    });

    const interval = setInterval(() => {
      if (!ws.isAlive) return ws.terminate();
      ws.isAlive = false;
      ws.ping();
    }, 30000);

    // Get user ID from token
    const userId = getUserIdFromRequest(req);
    if (userId) {
      const userIdStr = userId.toString();
      if (!userConnections[userIdStr]) {
        userConnections[userIdStr] = [];
      }
      userConnections[userIdStr].push(ws);

      // Initialize chat handling
      handleChatEvents(ws, userIdStr);

      // Send welcome message
      ws.send(
        JSON.stringify({
          type: "WELCOME",
          message: "Connected to Paxmata WebSocket server",
          userId: userIdStr,
        })
      );
    } else {
      console.log("No user ID found in WebSocket connection");
      ws.close(1008, "Unauthorized");
      return;
    }

    // Cleanup on connection close
    ws.on("close", () => {
      clearInterval(interval);
      if (userId) {
        const userIdStr = userId.toString();

        // Remove from user connections
        if (userConnections[userIdStr]) {
          userConnections[userIdStr] = userConnections[userIdStr].filter(
            (conn) => conn !== ws
          );
          if (userConnections[userIdStr].length === 0) {
            delete userConnections[userIdStr];
          }
        }

        // Remove from all project subscriptions
        projectSubscriptions.forEach((subscribers, projectId) => {
          subscribers.delete(userIdStr);
          if (subscribers.size === 0) {
            projectSubscriptions.delete(projectId);
          }
        });
      }
    });

    ws.on("error", (error) => {
      console.error("WebSocket error:", error);
    });
  });

  return wss;
};
const broadcastMessageToUser = (userId, message) => {
  if (!userId) {
    console.error("broadcastMessageToUser called with undefined userId");
    return;
  }

  const connections = getUserConnections(userId);
  if (connections.length > 0) {
    connections.forEach((client) => {
      if (client.readyState === WebSocket.OPEN) {
        client.send(JSON.stringify(message));
      }
    });
  } else {
    console.log("No active connections found for user:", userId);
  }
};

// Notification functions
const notifyProjectMinted = async (projectOwnerId, projectDetails) => {
  if (!projectOwnerId || !projectDetails) return;

  const message = {
    type: "PROJECT_MINTED",
    notification: {
      userId: projectOwnerId,
      type: "project_minted",
      message: `Your project has been minted and listed on the marketplace`,
      metadata: projectDetails,
      read: false,
      createdAt: new Date(),
    },
  };

  broadcastMessageToUser(projectOwnerId, message);
  await updateUserStats(projectOwnerId);
};

const updateUserStats = async (userId) => {
  if (!userId) return;

  try {
    const userIdStr = userId.toString();
    const projectContext = {
      projects: await Project.find({
        $or: [{ userId: userIdStr }, { developerId: userIdStr }],
      }),
      marketplaceProjects: await Project.find({
        status: "Listed",
        $or: [{ userId: userIdStr }, { developerId: userIdStr }],
      }),
      negotiationProjects: await Project.find({
        status: "In Negotiation",
        $or: [{ userId: userIdStr }, { developerId: userIdStr }],
      }),
    };

    const createStats = ProjectStatsCalculator.calculateCreateStats(
      projectContext,
      userIdStr
    );
    const buildStats = ProjectStatsCalculator.calculateBuildStats(
      projectContext,
      userIdStr
    );

    broadcastMessageToUser(userIdStr, {
      type: "statsUpdate",
      data: { createStats, buildStats },
    });
  } catch (error) {
    console.error("Error updating user stats:", error);
  }
};

const notifyProjectOwner = async (projectOwnerId, bidDetails) => {
  if (!projectOwnerId) {
    console.error("notifyProjectOwner called with undefined projectOwnerId");
    return;
  }
  if (!bidDetails) {
    console.error("notifyProjectOwner called with undefined bidDetails");
    return;
  }
  try {
    const bidderId = bidDetails.userId;
    if (!bidderId) {
      console.error("notifyProjectOwner called with undefined bidderId");
    }

    // Send bid notification to project owner
    broadcastMessageToUser(projectOwnerId, {
      type: "NEW_BID",
      notification: {
        userId: projectOwnerId,
        type: "new_bid",
        message: `New bid of ${bidDetails.amount} ${bidDetails.currency} received for project "${bidDetails.projectTitle}"`,
        metadata: bidDetails,
        read: false,
        createdAt: new Date(),
      },
    });

    // Update stats for both users
    await updateUserStats(projectOwnerId);
    if (bidderId) {
      await updateUserStats(bidderId);
    }
  } catch (error) {
    console.error("Error in bid notification process:", error);
    throw error;
  }
};

const notifyBidder = async (bidderId, projectDetails) => {
  if (!bidderId) {
    console.error("notifyBidder called with undefined bidderId");
    return;
  }
  if (!projectDetails) {
    console.error("notifyBidder called with undefined projectDetails");
    return;
  }

  const bidderIdStr = bidderId.toString();
  const projectOwnerIdStr = projectDetails.projectOwnerId
    ? projectDetails.projectOwnerId.toString()
    : null;

  const message = {
    type: "BID_ACCEPTED",
    notification: {
      userId: bidderId,
      type: "bid_accepted",
      message: `Your bid for project "${projectDetails.projectTitle}" has been accepted`,
      metadata: projectDetails,
      read: false,
      createdAt: new Date(),
    },
  };

  broadcastMessageToUser(bidderIdStr, message);

  // Update stats for both users
  await updateUserStats(bidderIdStr);
  if (projectOwnerIdStr) {
    await updateUserStats(projectOwnerIdStr);
  }
};

const notifyMilestonesAdded = async (
  projectOwnerId,
  developerId,
  projectDetails
) => {
  if (!projectOwnerId) {
    console.error("notifyMilestonesAdded called with undefined projectOwnerId");
    return;
  }
  if (!projectDetails) {
    console.error("notifyMilestonesAdded called with undefined projectDetails");
    return;
  }

  console.log("Milestones added, updating stats:", {
    projectOwnerId,
    developerId,
    projectId: projectDetails.projectId,
  });

  const message = {
    type: "MILESTONES_ADDED",
    notification: {
      type: "milestones_added",
      message: `Milestones have been added to project: ${projectDetails.title}`,
      metadata: {
        ...projectDetails,
        contractCreationBlock: projectDetails.contractCreationBlock,
        bidAcceptedBlock: projectDetails.bidAcceptedBlock,
        transactionHash: projectDetails.transactionHash,
      },
      read: false,
      createdAt: new Date(),
    },
  };

  console.log("Processing milestone notification with blocks:", {
    contractCreationBlock: projectDetails.contractCreationBlock,
    bidAcceptedBlock: projectDetails.bidAcceptedBlock,
  });

  // Send notifications to both parties
  broadcastMessageToUser(projectOwnerId, message);
  if (developerId) {
    broadcastMessageToUser(developerId, message);
  }

  // Process SCORS update
  try {
    if (!SCORSProcessor) {
      throw new Error("SCORSProcessor not properly initialized");
    }

    // Get bid acceptance block from project data
    const project = await Project.findById(projectDetails.projectId);
    if (!project?.bidAcceptedBlock) {
      console.warn("No bid acceptance block found for project");
      return;
    }

    const notification = {
      type: "contract_created",
      userId: developerId,
      metadata: {
        projectId: projectDetails.projectId,
        title: projectDetails.title,
        milestonesCount: projectDetails.milestonesCount,
        bidAcceptedBlock: project.bidAcceptedBlock, // Add bid block
        contractCreationBlock: projectDetails.blockNumber, // Add contract block
        transactionHash: projectDetails.transactionHash,
      },
    };

    console.log("Processing contract creation timing:", {
      bidAcceptedBlock: project.bidAcceptedBlock,
      contractCreationBlock: projectDetails.blockNumber,
    });

    const scorsResult = await SCORSProcessor.processNotification(notification);
    console.log("SCORS processing result:", scorsResult);

    if (scorsResult) {
      broadcastMessageToUser(developerId, {
        type: "SCORS_UPDATE",
        data: { newScore: scorsResult },
      });
    }
  } catch (error) {
    console.error("Error processing SCORS update:", error);
  }

  // Update stats for both parties
  await updateUserStats(projectOwnerId);
  if (developerId) await updateUserStats(developerId);
};

const notifyContractGenerated = async (
  projectOwnerId,
  developerId,
  contractDetails
) => {
  const ownerIdStr = projectOwnerId._id || projectOwnerId;
  const developerIdStr = developerId.toString();

  if (!ownerIdStr || !developerIdStr) {
    console.error("Missing required IDs:", { ownerIdStr, developerIdStr });
    return;
  }

  // Log incoming data for debugging
  console.log("Contract generated, updating stats:", {
    projectOwnerId,
    developerId,
    contractDetails,
    blockNumbers: {
      bidAccepted: contractDetails.bidAcceptedBlock,
      contractCreation: contractDetails.contractCreationBlock,
    },
  });

  // Validate block numbers
  if (
    !contractDetails.bidAcceptedBlock ||
    !contractDetails.contractCreationBlock
  ) {
    console.warn("Missing block numbers:", {
      bidAcceptedBlock: contractDetails.bidAcceptedBlock,
      contractCreationBlock: contractDetails.contractCreationBlock,
    });
  }

  const message = {
    type: "CONTRACT_GENERATED",
    notification: {
      type: "contract_created",
      message: "Contract has been generated and milestones set",
      metadata: {
        projectId: contractDetails.projectId,
        bidAcceptedBlock: contractDetails.bidAcceptedBlock,
        contractCreationBlock: contractDetails.contractCreationBlock,
        transactionHash: contractDetails.transactionHash,
        // Add timing information for SCORS
        contractCreationTime: new Date(),
        blockDifference:
          contractDetails.contractCreationBlock -
          contractDetails.bidAcceptedBlock,
      },
      read: false,
      createdAt: new Date(),
    },
  };

  try {
    console.log("Broadcasting to projectOwner:", ownerIdStr);
    broadcastMessageToUser(ownerIdStr, message);

    console.log("Broadcasting to developer:", developerIdStr);
    broadcastMessageToUser(developerIdStr, message);

    // Process SCORS updates with enhanced validation
    console.log("Processing SCORS notification for developer");
    await SCORSProcessor.processNotification({
      type: "contract_created",
      userId: developerIdStr,
      metadata: message.notification.metadata,
    });

    console.log("Processing SCORS notification for project owner");
    await SCORSProcessor.processNotification({
      type: "contract_created",
      userId: ownerIdStr,
      metadata: message.notification.metadata,
    });

    // Update stats for both parties with string IDs
    await updateUserStats(ownerIdStr);
    await updateUserStats(developerIdStr);
  } catch (error) {
    console.error("Error in contract generation notification:", error);
    console.error("Error context:", {
      projectOwnerId: ownerIdStr,
      developerId: developerIdStr,
      metadata: message.notification.metadata,
    });
  }
};

const notifyProjectCompletion = async (
  projectOwnerId,
  developerId,
  projectDetails
) => {
  if (!projectOwnerId) {
    console.error(
      "notifyProjectCompletion called with undefined projectOwnerId"
    );
    return;
  }
  if (!projectDetails || !projectDetails.projectId) {
    console.error("Missing required project details:", projectDetails);
    return;
  }

  console.log("Project completed, updating stats:", {
    projectOwnerId,
    developerId,
    projectDetails,
  });

  const message = {
    type: "PROJECT_COMPLETION",
    notification: {
      type: "project_completed",
      message: "Project has been completed and verified",
      metadata: {
        projectId: projectDetails.projectId,
        completionPercentage: projectDetails.completionPercentage,
        verificationPercentage: projectDetails.verificationPercentage,
      },
      read: false,
      createdAt: new Date(),
    },
  };

  // Send notifications
  broadcastMessageToUser(projectOwnerId, message);
  if (developerId) {
    broadcastMessageToUser(developerId, message);
  }

  // Process SCORS updates
  try {
    // Update owner's score
    const ownerScore = await SCORSProcessor.processNotification(
      message.notification
    );
    if (ownerScore) {
      broadcastMessageToUser(projectOwnerId, {
        type: "SCORS_UPDATE",
        data: { newScore: ownerScore },
      });
    }

    // Update developer's score
    if (developerId) {
      const devScore = await SCORSProcessor.processNotification({
        ...message.notification,
        userId: developerId,
      });
      if (devScore) {
        broadcastMessageToUser(developerId, {
          type: "SCORS_UPDATE",
          data: { newScore: devScore },
        });
      }
    }
  } catch (error) {
    console.error("Error processing SCORS update:", error);
  }

  await updateUserStats(projectOwnerId);
  if (developerId) await updateUserStats(developerId);
};

const notifyMilestoneCompleted = async (
  projectOwnerId,
  developerId,
  milestoneDetails
) => {
  if (!projectOwnerId || !developerId) {
    console.error("Missing required IDs:", { projectOwnerId, developerId });
    return;
  }
  if (!milestoneDetails) {
    console.error("Missing milestone details");
    return;
  }

  console.log("Milestone completed, updating stats:", {
    projectOwnerId,
    developerId,
    milestoneDetails,
  });

  const message = {
    type: "MILESTONE_COMPLETED",
    notification: {
      type: "milestone_completed",
      message: `Milestone "${milestoneDetails.title}" has been completed`,
      metadata: {
        projectId: milestoneDetails.projectId,
        milestoneId: milestoneDetails.milestoneId,
        completionPercentage: milestoneDetails.completionPercentage,
        deadline: milestoneDetails.deadline,
        completionTime: new Date(),
      },
      read: false,
      createdAt: new Date(),
    },
  };

  // Notify project owner
  broadcastMessageToUser(projectOwnerId, message);

  // Process SCORS update for developer
  try {
    const notification = {
      type: "milestone_completed",
      userId: developerId,
      metadata: message.notification.metadata,
    };
    const newScore = await SCORSProcessor.processNotification(notification);
    if (newScore) {
      broadcastMessageToUser(developerId, {
        type: "SCORS_UPDATE",
        data: { newScore },
      });
    }
  } catch (error) {
    console.error("Error processing SCORS update:", error);
  }

  // Update stats for both parties
  await updateUserStats(projectOwnerId);
  await updateUserStats(developerId);
};

const notifyMilestoneVerified = async (
  projectOwnerId,
  developerId,
  verificationDetails
) => {
  if (!projectOwnerId || !developerId) {
    console.error("Missing required IDs:", { projectOwnerId, developerId });
    return;
  }
  if (!verificationDetails) {
    console.error("Missing verification details");
    return;
  }

  console.log("Milestone verified, updating stats:", {
    projectOwnerId,
    developerId,
    verificationDetails,
  });

  const message = {
    type: "MILESTONE_VERIFIED",
    notification: {
      type: "milestone_verified",
      message: `Milestone "${verificationDetails.title}" has been verified`,
      metadata: {
        projectId: verificationDetails.projectId,
        milestoneId: verificationDetails.milestoneId,
        verificationPercentage: verificationDetails.verificationPercentage,
        completionTime: verificationDetails.completionTime,
        verificationTime: new Date(),
      },
      read: false,
      createdAt: new Date(),
    },
  };

  // Notify developer
  broadcastMessageToUser(developerId, message);

  // Process SCORS updates
  try {
    // Process owner's verification speed
    const ownerNotification = {
      type: "milestone_verified",
      userId: projectOwnerId,
      metadata: message.notification.metadata,
    };
    const ownerScore = await SCORSProcessor.processNotification(
      ownerNotification
    );
    if (ownerScore) {
      broadcastMessageToUser(projectOwnerId, {
        type: "SCORS_UPDATE",
        data: { newScore: ownerScore },
      });
    }

    // Update developer's score for verified milestone
    const devNotification = {
      type: "milestone_verified",
      userId: developerId,
      metadata: message.notification.metadata,
    };
    const devScore = await SCORSProcessor.processNotification(devNotification);
    if (devScore) {
      broadcastMessageToUser(developerId, {
        type: "SCORS_UPDATE",
        data: { newScore: devScore },
      });
    }
  } catch (error) {
    console.error("Error processing SCORS update:", error);
  }

  // Update stats for both parties
  await updateUserStats(projectOwnerId);
  await updateUserStats(developerId);
};

// Exported functions
module.exports = {
  initWebSocket,
  broadcastMessageToUser,
  updateUserStats,
  notifyProjectMinted,
  notifyProjectOwner,
  notifyContractGenerated,
  notifyBidder,
  notifyMilestonesAdded,
  notifyMilestoneCompleted,
  notifyMilestoneVerified,
  notifyProjectCompletion,
  // Include other notification functions as needed
};
