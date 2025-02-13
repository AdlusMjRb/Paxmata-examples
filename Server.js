const cookieParser = require("cookie-parser");
const helmet = require("helmet");
const express = require("express");
const mongoose = require("mongoose");
const morgan = require("morgan");
const cors = require("cors");
const http = require("http");
const loadEnvironment = require("./loadEnvironment");

// Import routes
const abiRoutes = require("./routes/abiRoutes");
const achievementRoutes = require("./routes/achievement");
const adminRoutes = require("./routes/adminRoutes");
const aiRoutes = require("./routes/aiRoutes");
const authRoutes = require("./routes/auth");
const authenticate = require("./middleware/authenticate");
const chatRoutes = require("./routes/chatRoutes");
const errorHandler = require("./middleware/errorHandler");
const kycRoutes = require("./routes/kycRoutes");
const milestoneRoutes = require("./routes/milestones");
const nftRoutes = require("./routes/nfts");
const notificationRoutes = require("./routes/notification");
const officeRoutes = require("./routes/office");
const paymentsRoutes = require("./routes/payments");
const profileStatsRoutes = require("./routes/profileStats");
const progressRoutes = require("./routes/progress");
const projectController = require("./controllers/projectController");
const projectRoutes = require("./routes/projects");
const reviewRoutes = require("./routes/reviews");
const scorsRoutes = require("./routes/scorsRoutes");
const uploadRoutes = require("./routes/upload");
const userProfileRoutes = require("./routes/userProfile");
const notificationController = require("./controllers/notificationController");
const scorsController = require("./controllers/scorsController");
const userProfileController = require("./controllers/userProfileController");

const app = express();
const PORT = process.env.PORT || 3003;

// Basic Middleware
app.use(express.json({ limit: "50mb" }));
app.use(express.urlencoded({ extended: true, limit: "50mb" }));
app.use(morgan("dev"));
app.use(cookieParser());

// Security Configuration
app.use(
  helmet({
    crossOriginResourcePolicy: { policy: "cross-origin" },
    contentSecurityPolicy: {
      directives: {
        defaultSrc: ["'self'"],
        connectSrc: [
          "'self'",
          "https://www.paxmata.com",
          "http://localhost:3000",
          "ws:",
          "wss:",
        ],
        imgSrc: ["'self'", "data:", "blob:", "https://storage.googleapis.com"],
        styleSrc: ["'self'", "'unsafe-inline'"],
        scriptSrc: ["'self'", "'unsafe-inline'", "'unsafe-eval'"],
      },
    },
  })
);

// CORS Configuration
const corsOptions = {
  origin: function (origin, callback) {
    const allowedOrigins = [
      "https://www.paxmata.com",
      "http://www.paxmata.com",
      "http://localhost:3000",
    ];

    if (!origin || allowedOrigins.indexOf(origin) !== -1) {
      callback(null, true);
    } else {
      console.log("Origin not allowed by CORS:", origin);
      callback(null, false);
    }
  },
  credentials: true,
  methods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
  allowedHeaders: ["Content-Type", "Authorization", "X-Requested-With"],
  exposedHeaders: ["Content-Length", "Authorization", "New-Token"],
  maxAge: 86400,
};

app.get("/api/test-gcs", authenticate, async (req, res) => {
  try {
    const { Storage } = require("@google-cloud/storage");
    const storage = new Storage({
      projectId: process.env.GCS_PROJECT_ID,
      credentials: JSON.parse(process.env.GCS_KEY_FILE),
    });

    const bucket = storage.bucket(process.env.GCS_BUCKET_NAME);
    const [exists] = await bucket.exists();
    const [files] = await bucket.getFiles({ maxResults: 5 });

    res.json({
      success: true,
      bucketExists: exists,
      bucketName: process.env.GCS_BUCKET_NAME,
      projectId: process.env.GCS_PROJECT_ID,
      sampleFiles: files.map((f) => f.name),
      keyFileValid: !!process.env.GCS_KEY_FILE,
    });
  } catch (error) {
    console.error("GCS Test Error:", error);
    res.status(500).json({
      success: false,
      error: error.message,
      stack: process.env.NODE_ENV === "development" ? error.stack : undefined,
    });
  }
});

app.use(cors(corsOptions));

// Health Check Route
app.get("/health", (req, res) => {
  res.json({
    status: "healthy",
    timestamp: new Date().toISOString(),
    environment: process.env.NODE_ENV,
  });
});

// Public Routes
app.get("/api/projects/marketplace", projectController.getMarketplaceProjects);
app.get(
  "/api/notifications/platform-stats",
  notificationController.getPlatformStats
);
app.get("/api/scors/top-developers", scorsController.getTopDevelopers);
app.get("/api/scors/user/:userId", scorsController.getUserScore);
app.get(
  "/api/profiles/users/:userId/profile",
  userProfileController.getUserProfile
);
// Auth Routes
app.use("/api/auth", authRoutes);

// Protected Routes
app.use("/api/abi", authenticate, abiRoutes);
app.use("/api/achievements", authenticate, achievementRoutes);
app.use("/api/ai", authenticate, aiRoutes);
app.use("/api/admin", authenticate, adminRoutes);
app.use("/api/chat", authenticate, chatRoutes);
app.use("/api/kyc", authenticate, kycRoutes);
app.use("/api/milestones", authenticate, milestoneRoutes);
app.use("/api/notifications", authenticate, notificationRoutes);
app.use("/api/nfts", authenticate, nftRoutes);
app.use("/api/office", authenticate, officeRoutes);
app.use("/api/payments", authenticate, paymentsRoutes);
app.use("/api/profiles", authenticate, userProfileRoutes);
app.use("/api/progress", authenticate, progressRoutes);
app.use("/api/projects", authenticate, projectRoutes);
app.use("/api/reviews", authenticate, reviewRoutes);
app.use("/api/scors", authenticate, scorsRoutes);
app.use("/api/stats", authenticate, profileStatsRoutes);
app.use("/api/upload", authenticate, uploadRoutes);

// 404 Handler
app.use((req, res) => {
  res.status(404).json({
    success: false,
    message: `Route not found: ${req.method} ${req.originalUrl}`,
  });
});

// Error Handler
app.use(errorHandler);

// Server Startup Function
const startServer = async () => {
  try {
    // Load environment variables
    console.log("Loading environment configuration...");
    const envVars = await loadEnvironment();

    // Apply environment variables
    Object.assign(process.env, envVars);

    // Verify Backend Signer
    const { backendSigner } = require("./utils/contracts");
    if (!backendSigner) {
      throw new Error("backendSigner is undefined");
    }
    const signerAddress = await backendSigner.getAddress();
    console.log(`Backend signer initialized: ${signerAddress}`);

    // Connect to MongoDB
    await mongoose.connect(process.env.MONGODB_URI, {
      maxPoolSize: 10,
      serverSelectionTimeoutMS: 30000,
      socketTimeoutMS: 45000,
    });
    console.log("Connected to MongoDB successfully");

    // Create HTTP server and initialize WebSocket
    const server = http.createServer(app);
    const { initWebSocket } = require("./websocket");
    const wss = initWebSocket(server);

    // Start server
    server.listen(PORT, () => {
      console.log(
        `Server running on port ${PORT} in ${process.env.NODE_ENV} mode`
      );
    });

    // Graceful Shutdown Handler
    const gracefulShutdown = async (signal) => {
      console.log(`Received ${signal}. Starting graceful shutdown...`);
      server.close(async () => {
        try {
          await mongoose.connection.close();
          console.log("MongoDB connection closed.");

          if (wss) {
            wss.close(() => {
              console.log("WebSocket server closed.");
              process.exit(0);
            });
          } else {
            process.exit(0);
          }
        } catch (err) {
          console.error("Error during shutdown:", err);
          process.exit(1);
        }
      });

      setTimeout(() => {
        console.error("Forced shutdown after timeout");
        process.exit(1);
      }, 10000).unref();
    };

    // Register shutdown handlers
    ["SIGTERM", "SIGINT"].forEach((signal) => {
      process.on(signal, () => gracefulShutdown(signal));
    });

    // Global error handlers
    process.on("unhandledRejection", (reason, promise) => {
      console.error("Unhandled Rejection at:", promise, "reason:", reason);
    });

    process.on("uncaughtException", (error) => {
      console.error("Uncaught Exception:", error);
      gracefulShutdown("UNCAUGHT_EXCEPTION");
    });
  } catch (error) {
    console.error("Server startup failed:", error);
    process.exit(1);
  }
};

// Start the server
startServer();
